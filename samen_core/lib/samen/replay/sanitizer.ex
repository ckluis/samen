defmodule Samen.Replay.Sanitizer do
  @moduledoc """
  The replay capture **sanitizer** — default-deny, record by reference (ADR-052 §2.2 rule 1).

  Every term the recorder captures (mount assigns, the changed assigns of a render, handle_params
  and handle_event params) passes through here BEFORE it reaches the in-flight buffer. Nothing
  else writes a frame. The output is built from a closed vocabulary (`Samen.Replay.Ref`,
  `Redacted`, `Dropped`, `Kept`, `Id`, `Record`, `Count`, `More`, `Shape`) plus numbers,
  booleans, `nil`, label-shaped atoms, dates/times, decimals, maps, lists and tuples of those.
  **A bare string never survives** — the build-time frame schema (`Samen.Replay.FrameSchema`)
  and the persist-time validator both refuse one.

  ## Decision table (as built)

  | Captured term | Recorded as |
  |---|---|
  | Ash record, vault-routed attribute (`pii do … end`, or a CDC `:token` column) | `%Ref{resource, pk, attribute, label}` — the value (tenant-plane CLEAR, `%Samen.Pii.Plaintext{}`, `%Samen.Masked{}`) is never read |
  | Ash record, attribute `Samen.Cdc.Projection.classify_columns/2` would project (bounded id / enum / timestamp / number / boolean, or a two-reviewer `non_pii!`-cleared column) | the value, sanitized (a cleared string → `Kept` if bounded, else `Redacted{:string}`) |
  | Ash record, any other attribute (freeform, unknown type, `sensitive?`) | `%Redacted{kind: :free_text, length: n}` |
  | Ash record, loaded relationship | the related record(s), same rules; calculations + aggregates are not captured |
  | bare `%Samen.Masked{}` (outside a record) | `%Redacted{kind: :masked, label: label}` — the `vt_*` token is NOT kept (ADR §2.2.1) |
  | bare `%Samen.Pii.Plaintext{}` | `%Redacted{kind: :vault_plaintext}` — no length |
  | bare string, assign key on the view's keep-list, ≤ #{120} codepoints, printable, not email/SSN/phone-shaped | `%Kept{value}` |
  | bare UUID string | `%Id{value}` |
  | any other bare string / non-UTF-8 binary / printable charlist | `%Redacted{kind: :string \\| :binary \\| :charlist, length: n}` |
  | number, boolean, `nil`, `Date`/`Time`/`DateTime`/`NaiveDateTime`, `Decimal` | kept |
  | atom | kept if label-shaped and not PII-shaped, else `%Redacted{kind: :atom}` |
  | map / list / tuple | recursed; depth cap #{8}, #{50} items per level (`%More{n}` marks the cut), #{5000} nodes per capture |
  | map key | an atom/integer, a label-shaped non-PII string, else a positional `"$kN"` |
  | `%Samen.Scope{}`, an actor map (`:plane` + an id), the framework actor/principal assigns | `%Dropped{kind: :scope \\| :actor}` |
  | socket, PID, port, reference, function | `%Dropped{}` of that kind |
  | `Phoenix.LiveView` stream / upload | `%Count{}` only (ADR-052 §7) |
  | a struct on the walk-list (`Samen.Web.Page`, `Phoenix.LiveView.AsyncResult`, host-extensible) | `%Record{}` of its fields, each sanitized |
  | any other struct (forms, changesets, `GeoSet` markers, …) | `%Dropped{kind: :struct, struct: "Module"}` — provenance unknown ⇒ dropped, never guessed |

  Event params are recorded by `params/3` as `%Shape{}` (key, type, length, PII-shape class);
  a value is kept only for a key on the event's declared keep-list (ADR-052 D3).

  ## Never crashes its caller

  Each top-level assign is sanitized inside its own `rescue`/`catch`: a value the walker cannot
  handle becomes `%Dropped{kind: :sanitizer_error}` and the rest of the frame is still built.
  """

  alias Samen.Replay.{Count, Dropped, Id, Kept, More, Record, Redacted, Ref, Shape}

  @max_depth 8
  @max_items 50
  @node_budget 5_000
  @max_kept 120
  @max_cleared 200
  @max_param_keys 32
  @max_param_depth 5

  # Assign keys that carry the actor / principal / scope: never captured, whatever their shape.
  # The session actor is recorded ONCE, as the HMAC pseudonym, on the session row.
  @actor_keys [
    :actor,
    :current_actor,
    :current_user,
    :user,
    :principal,
    :samen_tenant_principal,
    :samen_authorized_orgs
  ]
  @scope_keys [:scope, :current_scope, :samen_scope, :write_scope]

  @default_walk_structs [Samen.Web.Page, Phoenix.LiveView.AsyncResult]

  @budget_key {__MODULE__, :budget}
  @classify_key {__MODULE__, :classify_opts}

  @doc "The framework assign keys that are dropped as the actor."
  @spec actor_keys() :: [atom()]
  def actor_keys, do: @actor_keys

  @doc """
  Sanitize a LiveView assigns map.

  Options:

    * `:keep` — the view's declared keep-list (assign keys whose bare string value may be kept);
    * `:only` — sanitize only these keys (a render's `__changed__` keys);
    * `:walk_structs` — extra struct modules to walk field-by-field (default from config).
  """
  @spec assigns(map(), keyword()) :: map()
  def assigns(assigns, opts \\ []) when is_map(assigns) do
    keep = Keyword.get(opts, :keep, [])
    walk = walk_structs(opts)
    keys = Keyword.get(opts, :only) || Map.keys(assigns)
    begin(opts)

    {map, _i} =
      Enum.reduce(keys, {%{}, 0}, fn key, {acc, i} ->
        if key == :__changed__ or not Map.has_key?(assigns, key) do
          {acc, i}
        else
          {safe_key, i} = map_key(key, i)
          {Map.put(acc, safe_key, top(key, Map.fetch!(assigns, key), keep, walk)), i}
        end
      end)

    map
  after
    finish()
  end

  @doc """
  Sanitize one arbitrary term (no keep-list: every bare string is redacted).
  """
  @spec value(term(), keyword()) :: term()
  def value(term, opts \\ []) do
    begin(opts)
    guarded(fn -> walk(term, 0, walk_structs(opts)) end)
  after
    finish()
  end

  # Per-capture state: the node budget, and the classifier options (`:non_pii_entries` — the
  # `Samen.Cdc.Projection.classify_columns/2` injection seam, for tests).
  defp begin(opts) do
    Process.put(@budget_key, @node_budget)
    Process.put(@classify_key, Keyword.take(opts, [:non_pii_entries]))
  end

  defp finish do
    Process.delete(@budget_key)
    Process.delete(@classify_key)
  end

  @doc """
  Record `params` as SHAPE (ADR-052 D3): per key its type, length and `Samen.PiiValueShape`
  class. A top-level key in `keep` keeps its value when that value is a bounded label, an
  integer or a boolean; nothing else ever keeps a value. Keys themselves are kept only when
  label-shaped and not PII-shaped (a client can send any key), else positional (`"$kN"`).
  """
  @spec params(term(), [String.t()]) :: Shape.t()
  def params(params, keep \\ [])

  def params(params, keep) when is_map(params) and not is_struct(params) do
    guarded(fn -> shape(params, keep, 0) end)
  end

  def params(_params, _keep), do: %Shape{fields: []}

  # ---------------------------------------------------------------------------
  # Top level (assign keys)

  defp top(key, value, keep, walk) do
    guarded(fn ->
      cond do
        key in @actor_keys -> %Dropped{kind: :actor}
        key in @scope_keys -> %Dropped{kind: :scope}
        key == :streams and is_map(value) -> %Count{kind: :streams, n: stream_count(value)}
        key == :uploads and is_map(value) -> %Count{kind: :uploads, n: map_size(value)}
        is_binary(value) and key in keep -> kept(value, @max_kept)
        true -> walk(value, 0, walk)
      end
    end)
  end

  defp guarded(fun) do
    fun.()
  rescue
    _ -> %Dropped{kind: :sanitizer_error}
  catch
    _, _ -> %Dropped{kind: :sanitizer_error}
  end

  defp stream_count(streams) do
    Enum.count(streams, fn {k, _} ->
      is_atom(k) and k not in [:__changed__, :__configured__, :__ref__]
    end)
  end

  # ---------------------------------------------------------------------------
  # The walker

  defp walk(term, depth, walk) do
    if spend() do
      walk_term(term, depth, walk)
    else
      %Dropped{kind: :budget}
    end
  end

  defp walk_term(term, _depth, _walk) when is_nil(term) or is_boolean(term), do: term
  defp walk_term(term, _depth, _walk) when is_integer(term) or is_float(term), do: term
  defp walk_term(term, _depth, _walk) when is_atom(term), do: atom(term)
  defp walk_term(term, _depth, _walk) when is_binary(term), do: string(term)
  defp walk_term(term, _depth, _walk) when is_pid(term), do: %Dropped{kind: :pid}
  defp walk_term(term, _depth, _walk) when is_port(term), do: %Dropped{kind: :port}
  defp walk_term(term, _depth, _walk) when is_reference(term), do: %Dropped{kind: :reference}
  defp walk_term(term, _depth, _walk) when is_function(term), do: %Dropped{kind: :function}

  defp walk_term(term, _depth, _walk) when is_bitstring(term),
    do: %Redacted{kind: :binary, length: bit_size(term)}

  defp walk_term(_term, depth, _walk) when depth >= @max_depth, do: %Dropped{kind: :depth}
  defp walk_term(term, depth, walk) when is_list(term), do: list(term, depth, walk)

  defp walk_term(term, depth, walk) when is_tuple(term) do
    term |> Tuple.to_list() |> list(depth, walk) |> List.to_tuple()
  end

  defp walk_term(%{__struct__: mod} = term, depth, walk) when is_atom(mod),
    do: struct_value(mod, term, depth, walk)

  defp walk_term(term, depth, walk) when is_map(term) do
    if actor_map?(term), do: %Dropped{kind: :actor}, else: map(term, depth, walk)
  end

  defp walk_term(_term, _depth, _walk), do: %Dropped{kind: :sanitizer_error}

  # Each walked node costs one unit of the per-capture budget, so a pathological assign (a
  # 100k-row list) is cut short instead of stalling the LiveView.
  defp spend do
    case Process.get(@budget_key) do
      n when is_integer(n) and n > 0 ->
        Process.put(@budget_key, n - 1)
        true

      nil ->
        true

      _ ->
        false
    end
  end

  # An actor map (`Samen.Web.Plane.scope/2` builds `%{id: …, org_id: …, plane: …, role: …}`).
  defp actor_map?(map),
    do: Map.has_key?(map, :plane) and (Map.has_key?(map, :id) or Map.has_key?(map, :org_id))

  defp atom(atom) do
    if atom_label?(atom), do: atom, else: %Redacted{kind: :atom}
  end

  # Atoms come from a code-bounded set, so the label decision is memoized per process.
  defp atom_label?(atom) do
    key = {__MODULE__, :atom, atom}

    case Process.get(key) do
      nil ->
        value = label?(Atom.to_string(atom))
        Process.put(key, value)
        value

      value ->
        value
    end
  end

  defp string(bin) do
    cond do
      uuid?(bin) -> %Id{value: String.downcase(bin)}
      String.valid?(bin) -> %Redacted{kind: :string, length: str_length(bin)}
      true -> %Redacted{kind: :binary, length: byte_size(bin)}
    end
  end

  defp list([], _depth, _walk), do: []

  defp list(list, depth, walk) do
    if charlist?(list) do
      %Redacted{kind: :charlist, length: length(list)}
    else
      {head, rest} = take(list, @max_items)
      walked = Enum.map(head, &walk(&1, depth + 1, walk))
      if rest > 0, do: walked ++ [%More{n: rest}], else: walked
    end
  end

  # A printable charlist is text (`'Ada Lovelace'`), whatever its container says.
  defp charlist?([h | _] = list) when is_integer(h) do
    {head, _rest} = take(list, @max_items)
    Enum.all?(head, &is_integer/1) and :io_lib.printable_unicode_list(head)
  end

  defp charlist?(_), do: false

  # Proper or improper list: the first `n` elements and how many proper elements remain.
  defp take(list, n), do: take(list, n, [])
  defp take([h | t], n, acc) when n > 0, do: take(t, n - 1, [h | acc])
  defp take([], _n, acc), do: {Enum.reverse(acc), 0}
  defp take(rest, 0, acc) when is_list(rest), do: {Enum.reverse(acc), length(rest)}
  defp take(_improper, _n, acc), do: {Enum.reverse(acc), 0}

  defp map(map, depth, walk) do
    {entries, i, n} =
      Enum.reduce_while(map, {%{}, 0, 0}, fn {k, v}, {acc, i, n} ->
        if n >= @max_items do
          {:halt, {acc, i, n}}
        else
          {key, i} = map_key(k, i)
          {:cont, {Map.put(acc, key, walk(v, depth + 1, walk)), i, n + 1}}
        end
      end)

    _ = i
    rest = map_size(map) - n
    if rest > 0, do: Map.put(entries, "$more", %More{n: rest}), else: entries
  end

  # A map key: an atom/integer, or a label-shaped non-PII string — else positional.
  defp map_key(key, i) when is_atom(key) and not is_nil(key) and not is_boolean(key) do
    if atom_label?(key), do: {key, i}, else: {"$k#{i}", i + 1}
  end

  defp map_key(key, i) when is_integer(key) do
    if label?(Integer.to_string(key)), do: {key, i}, else: {"$k#{i}", i + 1}
  end

  defp map_key(key, i) when is_binary(key) do
    if label?(key), do: {key, i}, else: {"$k#{i}", i + 1}
  end

  defp map_key(_key, i), do: {"$k#{i}", i + 1}

  # ---------------------------------------------------------------------------
  # Structs

  defp struct_value(Samen.Masked, %{label: label}, _depth, _walk),
    do: %Redacted{kind: :masked, label: safe_label(label)}

  defp struct_value(Samen.Pii.Plaintext, _term, _depth, _walk),
    do: %Redacted{kind: :vault_plaintext}

  defp struct_value(Samen.Scope, _term, _depth, _walk), do: %Dropped{kind: :scope}
  defp struct_value(Phoenix.LiveView.Socket, _term, _depth, _walk), do: %Dropped{kind: :socket}
  defp struct_value(Ash.NotLoaded, _term, _depth, _walk), do: %Dropped{kind: :not_loaded}
  defp struct_value(Ash.ForbiddenField, _term, _depth, _walk), do: %Dropped{kind: :not_loaded}

  defp struct_value(mod, term, _depth, _walk) when mod in [Date, Time, DateTime, NaiveDateTime],
    do: term

  defp struct_value(Decimal, term, _depth, _walk), do: term

  defp struct_value(Phoenix.LiveView.LiveStream, term, _depth, _walk),
    do: %Count{kind: :stream, n: safe_length(Map.get(term, :inserts))}

  defp struct_value(Phoenix.LiveView.UploadConfig, term, _depth, _walk),
    do: %Count{kind: :upload, n: safe_length(Map.get(term, :entries))}

  defp struct_value(mod, term, depth, walk) do
    cond do
      ash_resource?(mod) -> record(mod, term, depth, walk)
      mod in walk -> walked_struct(mod, term, depth, walk)
      true -> %Dropped{kind: :struct, struct: struct_name(mod)}
    end
  end

  defp struct_name(mod) do
    name = inspect(mod)
    if Samen.Replay.FrameSchema.opaque_id?(name), do: name
  end

  defp safe_length(list) when is_list(list), do: length(list)
  defp safe_length(_), do: 0

  defp walked_struct(mod, term, depth, walk) do
    fields = term |> Map.from_struct() |> map(depth, walk)
    %Record{resource: inspect(mod), pk: nil, fields: fields}
  end

  defp walk_structs(opts) do
    extra =
      Keyword.get_lazy(opts, :walk_structs, fn ->
        :samen_core |> Application.get_env(Samen.Replay, []) |> Keyword.get(:walk_structs, [])
      end)

    @default_walk_structs ++ List.wrap(extra)
  end

  defp ash_resource?(mod) do
    key = {__MODULE__, :resource?, mod}

    case Process.get(key) do
      nil ->
        value = Ash.Resource.Info.resource?(mod)
        Process.put(key, value)
        value

      value ->
        value
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Ash records — by reference

  defp record(mod, record, depth, walk) do
    plan = plan(mod)
    pk = pk_value(record, plan.pk)

    fields =
      Enum.reduce(plan.attributes, %{}, fn {name, decision}, acc ->
        Map.put(
          acc,
          name,
          attribute(decision, name, Map.get(record, name), plan, pk, depth, walk)
        )
      end)

    fields =
      Enum.reduce(plan.relationships, fields, fn name, acc ->
        case Map.get(record, name) do
          %{__struct__: Ash.NotLoaded} -> acc
          nil -> acc
          related -> Map.put(acc, name, walk(related, depth + 1, walk))
        end
      end)

    %Record{resource: plan.name, pk: pk, fields: fields}
  end

  defp attribute(:ref, name, _value, plan, pk, _depth, _walk),
    do: %Ref{resource: plan.name, pk: pk, attribute: name, label: name}

  defp attribute(:keep, _name, value, _plan, _pk, depth, walk) when is_binary(value) do
    if uuid?(value), do: %Id{value: String.downcase(value)}, else: kept(value, @max_cleared)
  rescue
    _ -> walk(value, depth + 1, walk)
  end

  defp attribute(:keep, _name, value, _plan, _pk, depth, walk), do: walk(value, depth + 1, walk)
  defp attribute(:free, _name, value, _plan, _pk, _depth, _walk), do: free_text(value)

  defp free_text(value) when is_binary(value),
    do: %Redacted{kind: :free_text, length: if(String.valid?(value), do: str_length(value))}

  defp free_text(value) when is_map(value) and not is_struct(value),
    do: %Redacted{kind: :free_text, length: map_size(value)}

  defp free_text(value) when is_list(value),
    do: %Redacted{kind: :free_text, length: length(value)}

  defp free_text(_value), do: %Redacted{kind: :free_text}

  @doc false
  # The per-resource capture plan (memoized in the calling process — a LiveView sanitizes the
  # same resources render after render, and `classify_columns/2` reads the `non_pii!` registry).
  @spec plan(module()) :: map()
  def plan(mod) do
    classify_opts = Process.get(@classify_key) || []
    key = {__MODULE__, :plan, mod, classify_opts}

    case Process.get(key) do
      nil ->
        plan = build_plan(mod, classify_opts)
        Process.put(key, plan)
        plan

      plan ->
        plan
    end
  end

  defp build_plan(mod, classify_opts) do
    vault = mod |> Samen.Pii.Info.pii_attributes() |> MapSet.new(& &1.name)
    classes = mod |> Samen.Cdc.Projection.classify_columns(classify_opts) |> Map.new()

    attributes =
      for attr <- Ash.Resource.Info.attributes(mod) do
        column = to_string(attr.source || attr.name)
        {attr.name, decision(attr, MapSet.member?(vault, attr.name), Map.get(classes, column))}
      end

    %{
      name: inspect(mod),
      pk: Ash.Resource.Info.primary_key(mod),
      attributes: attributes,
      relationships: mod |> Ash.Resource.Info.relationships() |> Enum.map(& &1.name)
    }
  end

  # The ADR-015 decision, reused verbatim: vault-routed (declared, or a `:token` storage
  # column) → by reference; a `sensitive?` attribute → never kept; otherwise kept only when the
  # CDC classifier would project it.
  defp decision(_attr, true, _class), do: :ref
  defp decision(_attr, false, :token), do: :ref
  defp decision(%{sensitive?: true}, false, _class), do: :free
  defp decision(_attr, false, class) when class in [nil, :plaintext_pii], do: :free
  defp decision(_attr, false, _class), do: :keep

  defp pk_value(record, [field]) do
    case Map.get(record, field) do
      id when is_binary(id) -> if uuid?(id), do: String.downcase(id)
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp pk_value(_record, _fields), do: nil

  # ---------------------------------------------------------------------------
  # Kept strings + labels

  defp kept(value, max) do
    cond do
      not String.valid?(value) ->
        %Redacted{kind: :binary, length: byte_size(value)}

      byte_size(value) > max * 4 or str_length(value) > max or not String.printable?(value) ->
        %Redacted{kind: :string, length: str_length(value)}

      elem(Samen.PiiValueShape.classify_value(value), 0) ->
        %Redacted{kind: :string, length: str_length(value)}

      true ->
        %Kept{value: value}
    end
  end

  defp safe_label(label) when is_atom(label) and not is_nil(label) do
    if label?(Atom.to_string(label)), do: label, else: nil
  end

  defp safe_label(_), do: nil

  defp str_length(bin) when byte_size(bin) > 16_384, do: nil
  defp str_length(bin), do: String.length(bin)

  @doc false
  # A short identifier-shaped, non-PII-shaped label (the `Samen.Observability.LiveEvents`
  # label rule, plus `?`/`!` for predicate-style atoms). Never contains a space, `@` or `/`.
  @spec label?(String.t()) :: boolean()
  def label?(value) when is_binary(value),
    do:
      byte_size(value) <= 64 and Regex.match?(~r/\A[A-Za-z0-9_.:\-?!]{1,64}\z/, value) and
        not Samen.PiiValueShape.pii_shaped_id?(value)

  def label?(_), do: false

  @doc false
  @spec uuid?(term()) :: boolean()
  def uuid?(value) when is_binary(value) and byte_size(value) == 36 do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  def uuid?(_), do: false

  # ---------------------------------------------------------------------------
  # Event / URL params — shape, not content (D3)

  defp shape(params, keep, depth) do
    {fields, _i} =
      params
      |> Enum.take(@max_param_keys)
      |> Enum.map_reduce(0, fn {k, v}, i ->
        {key, i} = param_key(k, i)
        {param_field(key, k in keep, v, depth), i}
      end)

    %Shape{fields: fields, more: max(map_size(params) - @max_param_keys, 0)}
  end

  defp param_key(key, i) when is_binary(key) do
    if label?(key), do: {key, i}, else: {"$k#{i}", i + 1}
  end

  defp param_key(key, i) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: param_key(Atom.to_string(key), i)

  defp param_key(_key, i), do: {"$k#{i}", i + 1}

  defp param_field(key, keep?, value, depth) do
    field = %{key: key, type: param_type(value), length: param_length(value), class: class(value)}

    field =
      if keep? and keepable?(value),
        do: Map.put(field, :value, value),
        else: field

    if is_map(value) and not is_struct(value) and depth + 1 < @max_param_depth do
      Map.put(field, :fields, shape(value, [], depth + 1).fields)
    else
      field
    end
  end

  defp param_type(v) when is_binary(v), do: :string
  defp param_type(v) when is_integer(v), do: :integer
  defp param_type(v) when is_float(v), do: :float
  defp param_type(v) when is_boolean(v), do: :boolean
  defp param_type(nil), do: :null
  defp param_type(v) when is_map(v), do: :map
  defp param_type(v) when is_list(v), do: :list
  defp param_type(_), do: :other

  defp param_length(v) when is_binary(v),
    do: if(String.valid?(v), do: str_length(v), else: byte_size(v))

  defp param_length(v) when is_map(v), do: map_size(v)
  defp param_length(v) when is_list(v), do: length(v)
  defp param_length(_), do: nil

  defp class(v) when is_binary(v) do
    cond do
      uuid?(v) -> :uuid
      true -> v |> Samen.PiiValueShape.classify_id_value() |> elem(1) |> Kernel.||(:none)
    end
  end

  defp class(v) when is_number(v), do: :number
  defp class(_), do: :none

  # A keep-listed value is kept only when it is a bounded label (a sort field, a page
  # direction, a filter enum), an integer or a boolean — never free text, even keep-listed.
  defp keepable?(v) when is_binary(v), do: label?(v)
  defp keepable?(v) when is_integer(v) or is_boolean(v), do: true
  defp keepable?(_), do: false
end
