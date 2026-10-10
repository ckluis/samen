defmodule Samen.Replay.FrameSchema do
  @moduledoc """
  The declared, bounded **frame schema** for `Samen.Replay` (ADR-052 §2.2 rule 3) — the replay
  twin of `Samen.WideEvent.Schema`.

  Every field a persisted frame may carry is declared here with a bounded type. The
  build-time check `mix samen.verify.replay_schema` fails on any field typed as a free-form
  string (or any type not in `bounded_types/0`), on an enum with no closed set, on the reserved
  `allowed: :open` sentinel outside `open_enum_fields/0`, and on a `:keep_listed` field without
  a bounded `max_length`. At persist time `validate/1` walks every encoded frame against the
  same declaration, so a frame carrying a bare string anywhere in its tree is refused, not
  stored.

  ## Bounded field types

    * `:opaque_id`   — a code identifier (a route template). `[A-Za-z0-9_./:*-]{1,200}`, never
      email/SSN/phone-shaped.
    * `:module_name` — an Elixir module name as `inspect/1` prints it (`Samen.Web.Page`).
    * `:md5`         — 32 lowercase hex characters.
    * `:uuid`        — a lowercase UUID (the sanitizer downcases every id it keeps).
    * `:pk`          — a primary key: a lowercase UUID or an integer.
    * `:field_name`  — an attribute name (`[a-z_][A-Za-z0-9_]*[?!]?`, ≤ 64).
    * `:label`       — a short label-shaped, non-PII string (`Samen.Replay.Sanitizer.label?/1`).
    * `:param_key`   — a params key: a positional `$kN`, or a label-shaped string that names
      something the server already knows (an existing atom, a UUID, a list index of ≤ 3
      digits) — exactly `Samen.Replay.Sanitizer.known_key?/1`.
    * `:enum`        — a value from a declared closed set (`allowed:`), or — only for
      `open_enum_fields/0` — a label resolved from developer code (an event literal, an
      atom), validated label-shaped at persist.
    * `:number`, `:boolean`, `:timestamp` (ISO-8601).
    * `:tree`        — a sanitized term (`Samen.Replay.Sanitizer`): JSON scalars, arrays,
      objects with label keys, and the marker nodes declared in `markers/0`. **No bare string.**
    * `:shape`       — a `Samen.Replay.Shape` param shape (key/type/length/class).
    * `:keep_listed` — the ONE text type: a string a view explicitly declared on its keep-list,
      bounded by `max_length:` and refused when email/SSN/phone-shaped.

  Anything else — `:string`, `:binary`, `:text`, `:map`, `:any`, `:term`, … — is a
  name-carrier and fails the build.
  """

  alias Samen.Replay.{Count, Dropped, Id, Kept, More, Record, Redacted, Ref, Shape}

  @bounded_types [
    :opaque_id,
    :module_name,
    :md5,
    :uuid,
    :pk,
    :field_name,
    :label,
    :param_key,
    :enum,
    :number,
    :boolean,
    :timestamp,
    :tree,
    :shape,
    :keep_listed
  ]
  @known_forbidden [:string, :binary, :text, :map, :any, :term, :list, :atom]
  @max_keep_listed 200

  @kinds [:mount, :params, :event, :component_event, :render, :info, :exit, :truncated]
  @exit_reasons [:normal, :shutdown, :killed, :crash]
  @caps [:max_frames, :max_bytes]
  @param_types [:string, :integer, :float, :boolean, :null, :map, :list, :other]
  @param_classes [:email, :ssn, :phone, :name, :uuid, :number, :none]
  @dt_types [:date, :time, :datetime, :naive]

  @module_name ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @md5 ~r/\A[0-9a-f]{32}\z/
  @lower_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @field_name ~r/\A[a-z_][A-Za-z0-9_]{0,62}[?!]?\z/

  @envelope [
    {:seq, :number, []},
    {:at_ms, :number, []},
    {:kind, :enum, [allowed: @kinds]}
  ]

  @payloads %{
    mount: [
      {:view, :module_name, []},
      {:view_md5, :md5, []},
      {:live_action, :enum, [allowed: :open]},
      {:assigns, :tree, []}
    ],
    params: [{:route, :opaque_id, []}, {:params, :shape, []}],
    event: [{:event, :enum, [allowed: :open]}, {:params, :shape, []}],
    component_event: [
      {:component, :module_name, []},
      {:event, :enum, [allowed: :open]},
      {:params, :shape, []}
    ],
    render: [{:assigns, :tree, []}],
    info: [{:tag, :enum, [allowed: :open]}],
    exit: [{:reason, :enum, [allowed: @exit_reasons]}],
    truncated: [{:cap, :enum, [allowed: @caps]}]
  }

  @markers %{
    "$ref" => [
      {:resource, :module_name, []},
      {:pk, :pk, []},
      {:attribute, :field_name, []},
      {:label, :field_name, []}
    ],
    "$redacted" => [
      {:kind, :enum, [allowed: Redacted.kinds()]},
      {:length, :number, []},
      {:label, :label, []}
    ],
    "$dropped" => [{:kind, :enum, [allowed: Dropped.kinds()]}, {:struct, :module_name, []}],
    "$kept" => [{:value, :keep_listed, [max_length: @max_keep_listed]}],
    "$id" => [{:value, :uuid, []}],
    "$atom" => [{:value, :enum, [allowed: :open]}],
    "$dt" => [{:type, :enum, [allowed: @dt_types]}, {:value, :timestamp, []}],
    "$dec" => [{:value, :number, []}],
    "$record" => [{:resource, :module_name, []}, {:pk, :pk, []}, {:fields, :tree, []}],
    "$count" => [
      {:kind, :enum, [allowed: [:stream, :upload, :streams, :uploads]]},
      {:n, :number, []}
    ],
    "$more" => [{:n, :number, []}],
    "$tuple" => [{:items, :tree, []}],
    "$shape" => [{:fields, :shape, []}, {:more, :number, []}]
  }

  @shape_field [
    {:key, :param_key, []},
    {:type, :enum, [allowed: @param_types]},
    {:length, :number, []},
    {:class, :enum, [allowed: @param_classes]},
    {:value, :enum, [allowed: :open]},
    {:fields, :shape, []}
  ]

  # The fields allowed the `allowed: :open` sentinel: each is resolved from DEVELOPER code
  # (a `handle_event` literal / declared keep key, an atom, a `live_action`), never client
  # input, and validated label-shaped at persist.
  @open_enum_fields [:event, :tag, :live_action, :value]

  @typedoc "A field spec `{name, type, opts}`."
  @type field_spec :: {atom(), atom(), keyword()}

  @doc "The bounded field types."
  @spec bounded_types() :: [atom()]
  def bounded_types, do: @bounded_types

  @doc "Known forbidden types (named for a precise diagnostic; ANY non-bounded type fails)."
  @spec known_forbidden_types() :: [atom()]
  def known_forbidden_types, do: @known_forbidden

  @doc "The frame kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The bounded exit reasons."
  @spec exit_reasons() :: [atom()]
  def exit_reasons, do: @exit_reasons

  @doc "Fields that may declare `allowed: :open`."
  @spec open_enum_fields() :: [atom()]
  def open_enum_fields, do: @open_enum_fields

  @doc "The frame envelope fields."
  @spec envelope() :: [field_spec()]
  def envelope, do: @envelope

  @doc "Payload fields per frame kind."
  @spec payloads() :: %{atom() => [field_spec()]}
  def payloads, do: @payloads

  @doc "The tree marker nodes and their fields."
  @spec markers() :: %{String.t() => [field_spec()]}
  def markers, do: @markers

  @doc "The fields of one `$shape` entry."
  @spec shape_field() :: [field_spec()]
  def shape_field, do: @shape_field

  @doc """
  Every declared field spec, labelled by where it lives — the input of `violations/1`.
  """
  @spec all_fields() :: [{String.t(), field_spec()}]
  def all_fields do
    Enum.map(@envelope, &{"envelope", &1}) ++
      Enum.flat_map(@payloads, fn {kind, fields} -> Enum.map(fields, &{"payload #{kind}", &1}) end) ++
      Enum.flat_map(@markers, fn {m, fields} -> Enum.map(fields, &{"marker #{m}", &1}) end) ++
      Enum.map(@shape_field, &{"shape field", &1})
  end

  # ---------------------------------------------------------------------------
  # Build-time check (mix samen.verify.replay_schema)

  @doc """
  Validate the SCHEMA itself (the build-time check). Returns violation strings; empty = clean.
  Accepts an override field list so red-path tests can seed a free-string field without
  mutating the real schema.
  """
  @spec violations([{String.t(), field_spec()}]) :: [String.t()]
  def violations(fields \\ all_fields()) do
    Enum.flat_map(fields, fn
      {where, {name, type, opts}} when is_atom(name) and is_atom(type) and is_list(opts) ->
        field_violations(where, name, type, opts)

      other ->
        [
          "malformed replay frame field spec #{inspect(other)} — expected {where, {name, type, opts}}."
        ]
    end)
  end

  defp field_violations(where, name, type, opts) do
    cond do
      type not in @bounded_types ->
        [
          "#{where}: field #{inspect(name)} is typed #{inspect(type)} — a FORBIDDEN (name-carrier) " <>
            "type. Replay frame fields must be one of #{inspect(@bounded_types)}. A " <>
            "#{inspect(type)} field could carry tenant plaintext into the replay tables " <>
            "(ADR-052 §2.2 rule 3)."
        ]

      type == :enum and not valid_enum?(opts) ->
        ["#{where}: enum field #{inspect(name)} declares no closed `allowed:` set."]

      type == :enum and opts[:allowed] == :open and name not in @open_enum_fields ->
        [
          "#{where}: enum field #{inspect(name)} declares the reserved `allowed: :open` sentinel, " <>
            "which only #{inspect(@open_enum_fields)} may use."
        ]

      type == :keep_listed and
          not (is_integer(opts[:max_length]) and opts[:max_length] in 1..@max_keep_listed) ->
        [
          "#{where}: :keep_listed field #{inspect(name)} must declare max_length: 1..#{@max_keep_listed} " <>
            "— the only text type is a bounded, developer-declared one."
        ]

      true ->
        []
    end
  end

  defp valid_enum?(opts) do
    case opts[:allowed] do
      :open -> true
      [_ | _] = list -> Enum.all?(list, &is_atom/1)
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Encoding (sanitized term → JSON-able map)

  @doc """
  Encode one buffered frame `{seq, at_ms, kind, payload}` into its persisted form:
  `%{seq, at_ms, kind, payload}` with `payload` a JSON-able map.
  """
  @spec encode({non_neg_integer(), non_neg_integer(), atom(), map()}) :: map()
  def encode({seq, at_ms, kind, payload}) do
    %{
      seq: seq,
      at_ms: at_ms,
      kind: kind,
      payload: Map.new(payload, fn {k, v} -> {Atom.to_string(k), encode_field(k, v)} end)
    }
  end

  defp encode_field(_k, %Shape{} = shape), do: encode_shape(shape)
  defp encode_field(_k, v) when is_map(v) and not is_struct(v), do: encode_tree(v)

  defp encode_field(_k, v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp encode_field(_k, v), do: v

  @doc false
  @spec encode_tree(term()) :: term()
  def encode_tree(v) when is_nil(v) or is_boolean(v) or is_number(v), do: v
  # A bare string is passed through UNCHANGED so `validate/1` refuses the frame (and the store
  # counts it in `rejected_count`) — the encoder never launders a sanitizer bug into a marker.
  def encode_tree(v) when is_binary(v), do: v
  def encode_tree(v) when is_atom(v), do: marker("$atom", %{"value" => Atom.to_string(v)})
  def encode_tree(v) when is_list(v), do: Enum.map(v, &encode_tree/1)

  def encode_tree(%Ref{} = r) do
    marker("$ref", %{
      "resource" => r.resource,
      "pk" => r.pk,
      "attribute" => to_str(r.attribute),
      "label" => to_str(r.label)
    })
  end

  def encode_tree(%Redacted{} = r),
    do:
      marker("$redacted", %{
        "kind" => to_str(r.kind),
        "length" => r.length,
        "label" => to_str(r.label)
      })

  def encode_tree(%Dropped{} = d),
    do: marker("$dropped", %{"kind" => to_str(d.kind), "struct" => d.struct})

  def encode_tree(%Kept{value: v}), do: marker("$kept", %{"value" => v})
  def encode_tree(%Id{value: v}), do: marker("$id", %{"value" => v})

  def encode_tree(%Record{} = r),
    do:
      marker("$record", %{
        "resource" => r.resource,
        "pk" => r.pk,
        "fields" => encode_tree(r.fields)
      })

  def encode_tree(%Count{} = c), do: marker("$count", %{"kind" => to_str(c.kind), "n" => c.n})
  def encode_tree(%More{n: n}), do: marker("$more", %{"n" => n})
  def encode_tree(%Shape{} = s), do: encode_shape(s)

  def encode_tree(%Date{} = d),
    do: marker("$dt", %{"type" => "date", "value" => Date.to_iso8601(d)})

  def encode_tree(%Time{} = t),
    do: marker("$dt", %{"type" => "time", "value" => Time.to_iso8601(t)})

  def encode_tree(%DateTime{} = t),
    do: marker("$dt", %{"type" => "datetime", "value" => DateTime.to_iso8601(t)})

  def encode_tree(%NaiveDateTime{} = t),
    do: marker("$dt", %{"type" => "naive", "value" => NaiveDateTime.to_iso8601(t)})

  def encode_tree(%Decimal{} = d), do: marker("$dec", %{"value" => Decimal.to_string(d, :normal)})

  def encode_tree(v) when is_tuple(v),
    do: marker("$tuple", %{"items" => v |> Tuple.to_list() |> Enum.map(&encode_tree/1)})

  def encode_tree(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, val} -> {to_str(k), encode_tree(val)} end)

  def encode_tree(_other), do: marker("$dropped", %{"kind" => "sanitizer_error", "struct" => nil})

  defp encode_shape(%Shape{fields: fields, more: more}),
    do: marker("$shape", %{"fields" => Enum.map(fields, &encode_shape_field/1), "more" => more})

  defp encode_shape_field(field) do
    Map.new(field, fn
      {:fields, nested} ->
        {"fields", Enum.map(nested, &encode_shape_field/1)}

      {k, v} when is_atom(v) and not is_nil(v) and not is_boolean(v) ->
        {Atom.to_string(k), Atom.to_string(v)}

      {k, v} ->
        {Atom.to_string(k), v}
    end)
  end

  defp marker(name, body), do: %{name => body}

  defp to_str(nil), do: nil
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: inspect(v)

  # ---------------------------------------------------------------------------
  # Persist-time validation (the runtime defence)

  @doc """
  Validate one ENCODED frame against the declaration. `:ok` or `{:error, reason}` — the reason
  names the path, never the offending value.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{seq: seq, at_ms: at_ms, kind: kind, payload: payload}) when is_map(payload) do
    with :ok <- check(:number, seq, [], "seq"),
         :ok <- check(:number, at_ms, [], "at_ms"),
         :ok <- check(:enum, kind, [allowed: @kinds], "kind"),
         {:ok, fields} <- payload_fields(kind) do
      check_object(payload, fields, "payload")
    end
  catch
    {:invalid, path} -> {:error, path}
  end

  def validate(_), do: {:error, "frame"}

  defp payload_fields(kind) do
    case Map.fetch(@payloads, to_atom(kind)) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, "kind"}
    end
  end

  defp to_atom(kind) when is_atom(kind), do: kind
  defp to_atom(kind) when is_binary(kind), do: Enum.find(@kinds, &(Atom.to_string(&1) == kind))

  # An object with declared fields: every present key must be declared, every value must
  # check against its type. Absent fields are allowed (nil).
  defp check_object(object, fields, path) when is_map(object) do
    declared = Map.new(fields, fn {name, type, opts} -> {Atom.to_string(name), {type, opts}} end)

    Enum.reduce_while(object, :ok, fn {k, v}, :ok ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      case Map.fetch(declared, key) do
        {:ok, {type, opts}} ->
          case check(type, v, opts, "#{path}.#{key}") do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end

        :error ->
          {:halt, {:error, "#{path}: undeclared field"}}
      end
    end)
  end

  defp check_object(_object, _fields, path), do: {:error, path}

  defp check(_type, nil, _opts, _path), do: :ok

  defp check(:number, v, _opts, _path) when is_number(v), do: :ok

  defp check(:number, v, _opts, path) when is_binary(v) do
    if Regex.match?(~r/\A-?\d{1,40}(\.\d{1,40})?\z/, v), do: :ok, else: {:error, path}
  end

  defp check(:boolean, v, _opts, _path) when is_boolean(v), do: :ok
  defp check(:opaque_id, v, _opts, _path) when is_integer(v), do: :ok

  defp check(:opaque_id, v, _opts, path) when is_binary(v) do
    if opaque_id?(v), do: :ok, else: {:error, path}
  end

  # The identifier types are EXACTLY what the sanitizer/capture can emit (ADR-052 §2.4.1):
  # anything looser lets a row carry a label-shaped name the recorder never writes.
  defp check(:module_name, v, _opts, path), do: ok_if(module_name?(v), path)
  defp check(:md5, v, _opts, path), do: ok_if(is_binary(v) and Regex.match?(@md5, v), path)
  defp check(:uuid, v, _opts, path), do: ok_if(lower_uuid?(v), path)
  defp check(:pk, v, _opts, path), do: ok_if(is_integer(v) or lower_uuid?(v), path)
  defp check(:field_name, v, _opts, path), do: ok_if(field_name?(v), path)
  defp check(:label, v, _opts, path), do: ok_if(Samen.Replay.Sanitizer.label?(v), path)
  defp check(:param_key, v, _opts, path), do: ok_if(param_key?(v), path)

  defp check(:enum, v, opts, path) do
    s = if is_atom(v) and not is_boolean(v), do: Atom.to_string(v), else: v

    case opts[:allowed] do
      :open ->
        cond do
          is_binary(s) and Samen.Replay.Sanitizer.label?(s) -> :ok
          is_integer(s) or is_boolean(s) -> :ok
          true -> {:error, path}
        end

      allowed when is_list(allowed) ->
        if is_binary(s) and s in Enum.map(allowed, &Atom.to_string/1),
          do: :ok,
          else: {:error, path}
    end
  end

  defp check(:timestamp, v, _opts, path) when is_binary(v) do
    ok? =
      match?({:ok, _}, Date.from_iso8601(v)) or match?({:ok, _}, Time.from_iso8601(v)) or
        match?({:ok, _, _}, DateTime.from_iso8601(v)) or
        match?({:ok, _}, NaiveDateTime.from_iso8601(v))

    if ok?, do: :ok, else: {:error, path}
  end

  defp check(:keep_listed, v, opts, path) when is_binary(v) do
    max = opts[:max_length] || 0

    if String.valid?(v) and String.length(v) <= max and String.printable?(v) and
         not elem(Samen.PiiValueShape.classify_value(v), 0),
       do: :ok,
       else: {:error, path}
  end

  defp check(:tree, v, _opts, path), do: check_tree(v, path)

  defp check(:shape, %{"$shape" => body} = v, _opts, path) when map_size(v) == 1,
    do: check_object(body, @markers["$shape"], path <> ".$shape")

  defp check(:shape, v, _opts, path) when is_list(v) do
    Enum.reduce_while(Enum.with_index(v), :ok, fn {field, i}, :ok ->
      case check_object(field, @shape_field, "#{path}[#{i}]") do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check(_type, _v, _opts, path), do: {:error, path}

  # The tree grammar: scalars, arrays, label-keyed objects, declared marker nodes. A bare
  # string anywhere is refused.
  defp check_tree(v, _path) when is_nil(v) or is_boolean(v) or is_number(v), do: :ok

  defp check_tree(v, path) when is_list(v) do
    Enum.reduce_while(Enum.with_index(v), :ok, fn {item, i}, :ok ->
      case check_tree(item, "#{path}[#{i}]") do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check_tree(v, path) when is_map(v) and map_size(v) == 1 do
    [{k, body}] = Map.to_list(v)

    case Map.fetch(@markers, k) do
      {:ok, fields} -> check_object(body, fields, "#{path}.#{k}")
      :error -> check_plain_object(v, path)
    end
  end

  defp check_tree(v, path) when is_map(v), do: check_plain_object(v, path)
  defp check_tree(_v, path), do: {:error, "#{path}: bare value"}

  defp check_plain_object(v, path) do
    Enum.reduce_while(v, :ok, fn {k, val}, :ok ->
      cond do
        not tree_key?(k) ->
          {:halt, {:error, "#{path}: key"}}

        true ->
          case check_tree(val, "#{path}.#{k}") do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
      end
    end)
  end

  defp ok_if(true, _path), do: :ok
  defp ok_if(_false, path), do: {:error, path}

  @doc """
  A plain tree map key, exactly as the sanitizer writes one (`map_key/2`): the `$more` tail
  marker, a positional `$kN`, or a label-shaped, non-PII string that is a UUID, an integer (an
  integer key encodes as its digits) or an EXISTING atom (an atom key, or a string key naming
  one). A label-shaped string the server never knew — a name a row or a client chose — is
  refused, so a hostile row cannot carry it as a key.
  """
  @spec tree_key?(term()) :: boolean()
  def tree_key?(k) when is_binary(k) do
    k == "$more" or positional?(k) or
      (Samen.Replay.Sanitizer.label?(k) and
         (Samen.Replay.Sanitizer.uuid?(k) or Regex.match?(~r/\A-?\d+\z/, k) or
            existing_atom?(k)))
  end

  def tree_key?(_), do: false

  @doc "A params key exactly as the sanitizer writes one: `$kN` or `Sanitizer.known_key?/1`."
  @spec param_key?(term()) :: boolean()
  def param_key?(k) when is_binary(k), do: positional?(k) or Samen.Replay.Sanitizer.known_key?(k)
  def param_key?(_), do: false

  @doc "An Elixir module name as `inspect/1` prints one (`Samen.Web.CRM.ContactsLive`)."
  @spec module_name?(term()) :: boolean()
  def module_name?(v) when is_binary(v),
    do: byte_size(v) <= 200 and Regex.match?(@module_name, v)

  def module_name?(_), do: false

  @doc "An Ash attribute name as `Atom.to_string/1` prints one (`full_name`, `active?`)."
  @spec field_name?(term()) :: boolean()
  def field_name?(v) when is_binary(v), do: Regex.match?(@field_name, v)
  def field_name?(_), do: false

  defp lower_uuid?(v), do: is_binary(v) and Regex.match?(@lower_uuid, v)
  defp positional?(k), do: Regex.match?(~r/\A\$k\d{1,6}\z/, k)

  defp existing_atom?(k) do
    _ = String.to_existing_atom(k)
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  @spec opaque_id?(String.t()) :: boolean()
  def opaque_id?(v) when is_binary(v) do
    byte_size(v) <= 200 and Regex.match?(~r/\A[A-Za-z0-9_.\/:*\-]{1,200}\z/, v) and
      not elem(Samen.PiiValueShape.classify_value(v), 0)
  end

  def opaque_id?(_), do: false
end
