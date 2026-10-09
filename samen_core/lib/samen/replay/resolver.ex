defmodule Samen.Replay.Resolver do
  @moduledoc """
  The replay **view-time resolver** (ADR-052 §2.3 rule 1) — the one place a stored replay
  reference becomes a value, and it does so on the **viewer's** plane, never the recording
  actor's.

  A recording holds no PII value: each vault-routed attribute was stored as a
  `%Samen.Replay.Ref{resource, pk, attribute}` (§2.2 rule 1). To show a frame, the player hands
  the frame's decoded assigns (`Samen.Replay.Decoder`) and the VIEWER's `%Samen.Scope{}` to
  `resolve/3`, which:

    1. collects every `Ref` in the tree and reads each referenced record through `Ash.read/2`
       **under the viewer's scope** (`Samen.Policy.OrgScope` and the resource's own policies
       apply — a record the viewer may not read is indistinguishable from a deleted one);
    2. passes the records through `Samen.Api.PiiResolution.resolve/4` with the viewer's actor —
       the SAME rule every live surface uses: tenant own-org → CLEAR; operator under
       impersonation → `%Samen.Masked{}` unless a live reveal grant covers the subject, then
       plaintext through the single vault chokepoint. On the operator plane each record's
       resolution runs inside a reveal span (`Samen.Tracer.with_reveal_span/3`, P1), so a
       granted replay reveal is as visible in the trace as any other;
    3. substitutes each `Ref` with its CURRENT value (late binding):

       | Outcome | Rendered as |
       |---|---|
       | plaintext (tenant, or operator with a live grant) | the value |
       | masked (operator without a grant) | `Placeholder :masked` → `••••` (the `vt_*` token never reaches a template) |
       | the subject is crypto-shredded | `Placeholder :shredded` |
       | the record is gone (deleted, or outside the viewer's org) | `Placeholder :gone` |
       | the resource/attribute is no longer vault-routed or no longer exists | `Placeholder :code_changed` |

  It never writes what it resolves: no cache table, no log line, no ETS, no process
  dictionary. Every call reads again, so a grant that expires — or an impersonation session
  that closes — between two calls takes effect on the next call (deny-on-read). The result is
  returned to the caller, which renders it and drops it.

  The rest of the decoded vocabulary becomes render terms too: `Record` → the resource struct
  with its captured fields (an Ash resource or a sanitizer walk-list struct ONLY — any other
  module a stored row names is `:code_changed`); a `{:safe, _}` tuple → `:redacted` (a row
  never becomes raw markup); `Redacted` → a `:redacted` placeholder (a label-only bare `Masked`
  → `:masked`); `Kept` and `Id` → their strings; `Count` → `:count`; `More` cut from lists;
  `Dropped` → `nil`, or a struct module's DEFAULT struct (code, not data).

  Tier-1 mutation target (`scripts/mutation/targets.tsv`).
  """

  require Ash.Query
  require Samen.Tracer

  alias Samen.Api.PiiResolution
  alias Samen.Masked
  alias Samen.Replay.{Count, Decoder, Dropped, Id, Kept, More, Placeholder, Record, Redacted, Ref, Sanitizer}

  @max_pks 500
  @deny_structs [Phoenix.LiveView.Socket, Samen.Scope]

  @typedoc "One resolved reference, for the player's reference table (no value)."
  @type report :: %{
          resource: String.t(),
          attribute: String.t(),
          pk: String.t() | integer() | nil,
          outcome: :clear | :masked | :shredded | :gone | :code_changed | :empty
        }

  @doc """
  Resolve a decoded tree for the viewer `scope`. Returns `%{value: render_tree, refs: [report]}`.

  Options (tests): `:grant` (the reveal grant checker, default the configured one),
  `:vault` (default `Samen.Vault`), `:repo` (default the resource's own repo),
  the subject's shred state is always the KMS attestation.
  """
  @spec resolve(term(), Samen.Scope.t(), keyword()) :: %{value: term(), refs: [report()]}
  def resolve(tree, %Samen.Scope{} = scope, opts \\ []) do
    table =
      tree
      |> collect(%{})
      |> Map.new(fn {resource, pks} -> {resource, read(resource, pks, scope, opts)} end)

    {value, refs} = substitute(tree, table, opts, [])
    %{value: value, refs: refs |> Enum.reverse() |> Enum.uniq()}
  end

  # ---------------------------------------------------------------------------
  # 1. Collect the references

  defp collect(%Ref{resource: resource, pk: pk}, acc) when is_binary(resource),
    do: Map.update(acc, resource, MapSet.new([pk]), &MapSet.put(&1, pk))

  defp collect(%Record{fields: fields}, acc), do: collect(fields, acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)

  defp collect(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect/2)

  defp collect(map, acc) when is_map(map) and not is_struct(map),
    do: map |> Map.values() |> Enum.reduce(acc, &collect/2)

  defp collect(_other, acc), do: acc

  # ---------------------------------------------------------------------------
  # 2. Read under the viewer's scope + resolve on the viewer's plane

  defp read(name, pks, scope, opts) do
    with mod when not is_nil(mod) <- Decoder.module(name),
         true <- Ash.Resource.Info.resource?(mod),
         [pk_field] <- Ash.Resource.Info.primary_key(mod) do
      # The decoder only ever yields a UUID, an integer or nil as a pk.
      ids = pks |> Enum.reject(&is_nil/1) |> Enum.take(@max_pks)
      {:ok, mod, records(mod, pk_field, ids, scope, opts)}
    else
      _ -> :code_changed
    end
  rescue
    _ -> :code_changed
  end

  defp records(_mod, _pk_field, [], _scope, _opts), do: %{}

  defp records(mod, pk_field, ids, scope, opts) do
    attrs = mod |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

    mod
    |> Ash.Query.ensure_selected(attrs)
    |> Ash.Query.filter(^Ash.Expr.ref(pk_field) in ^ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rows} ->
        rows
        # Belt over the resource's own policies: a row of ANOTHER org than the viewer's is
        # gone, even on a resource that declares no org policy (no cross-org replay, ever).
        |> Enum.filter(&same_org?(&1, scope.actor))
        |> Enum.map(&plane_resolve(&1, mod, scope.actor, opts))
        |> Map.new(&{normalize_pk(Map.get(&1, pk_field)), &1})

      {:error, _} ->
        # Fail safe: a read the viewer is refused looks exactly like a deleted record.
        %{}
    end
  rescue
    _ -> %{}
  end

  # The ONE resolution rule (PiiResolution) with the VIEWER's actor. On the operator plane it
  # runs inside a reveal span: a granted replay reveal is traced like any other reveal.
  defp plane_resolve(record, mod, actor, opts) do
    resolve_opts = Keyword.merge([repo: repo(mod, opts)], Keyword.take(opts, [:grant, :vault]))

    if operator?(actor) do
      Samen.Tracer.with_reveal_span(
        Samen.Reveal.span_name(),
        %{subject_id: subject_id(record, mod), reason: "replay"}
      ) do
        one(record, mod, actor, resolve_opts)
      end
    else
      one(record, mod, actor, resolve_opts)
    end
  end

  defp one(record, mod, actor, resolve_opts) do
    [resolved] = PiiResolution.resolve([record], mod, actor, resolve_opts)
    resolved
  rescue
    # A resolver failure never downgrades to plaintext: the record keeps its masked values.
    _ -> record
  end

  # Every `Samen.Resource` row carries `org_id`; it must be the viewer's org. A row without
  # one, or a viewer without one, fails closed (gone).
  defp same_org?(row, %{org_id: org}) when is_binary(org),
    do: is_binary(Map.get(row, :org_id)) and normalize_pk(Map.get(row, :org_id)) == normalize_pk(org)

  defp same_org?(_row, _actor), do: false

  defp operator?(%{plane: :operator}), do: true
  defp operator?(_), do: false

  defp repo(mod, opts) do
    Keyword.get_lazy(opts, :repo, fn -> AshPostgres.DataLayer.Info.repo(mod, :read) end)
  rescue
    _ -> nil
  end

  defp subject_id(record, mod) do
    case Ash.Resource.Info.primary_key(mod) do
      [field] -> record |> Map.get(field) |> normalize_pk() |> to_string_or_nil()
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Substitute

  defp substitute(%Ref{} = ref, table, opts, acc) do
    {value, outcome} = lookup(ref, table, opts)

    report = %{
      resource: short(ref.resource),
      attribute: ref.attribute,
      pk: ref.pk,
      outcome: outcome
    }

    {value, [report | acc]}
  end

  defp substitute(%Record{resource: name, fields: fields}, table, opts, acc) do
    {fields, acc} = substitute_map(fields, table, opts, acc)
    {build_struct(name, fields), acc}
  end

  defp substitute(%Redacted{kind: :masked}, _table, _opts, acc),
    do: {Placeholder.new(:masked), acc}

  defp substitute(%Redacted{length: n}, _table, _opts, acc),
    do: {Placeholder.new(:redacted, n), acc}

  defp substitute(%Kept{value: v}, _table, _opts, acc) when is_binary(v), do: {v, acc}
  defp substitute(%Id{value: v}, _table, _opts, acc) when is_binary(v), do: {v, acc}
  defp substitute(%Count{n: n}, _table, _opts, acc), do: {Placeholder.new(:count, n), acc}
  defp substitute(%More{}, _table, _opts, acc), do: {nil, acc}
  defp substitute(%Dropped{} = d, _table, _opts, acc), do: {dropped(d), acc}
  defp substitute(%Placeholder{} = p, _table, _opts, acc), do: {p, acc}

  defp substitute(%mod{} = v, _table, _opts, acc)
       when mod in [Date, Time, DateTime, NaiveDateTime, Decimal, Samen.Replay.Shape],
       do: {v, acc}

  # Any other struct is not part of the decoded vocabulary: never pass it on.
  defp substitute(v, _table, _opts, acc) when is_struct(v),
    do: {Placeholder.new(:code_changed), acc}

  defp substitute(list, table, opts, acc) when is_list(list) do
    {items, acc} =
      list
      |> Enum.reject(&match?(%More{}, &1))
      |> Enum.map_reduce(acc, fn item, a -> substitute(item, table, opts, a) end)

    {items, acc}
  end

  defp substitute(tuple, table, opts, acc) when is_tuple(tuple) do
    case substitute(Tuple.to_list(tuple), table, opts, acc) do
      # `{:safe, iodata}` is raw markup to Phoenix.HTML: a stored row never becomes markup.
      {[:safe | _], acc} -> {Placeholder.new(:redacted), acc}
      {items, acc} -> {List.to_tuple(items), acc}
    end
  end

  defp substitute(map, table, opts, acc) when is_map(map), do: substitute_map(map, table, opts, acc)
  defp substitute(v, _table, _opts, acc) when is_binary(v), do: {Placeholder.new(:redacted), acc}
  defp substitute(v, _table, _opts, acc), do: {v, acc}

  defp substitute_map(map, table, opts, acc) do
    Enum.reduce(map, {%{}, acc}, fn {k, v}, {m, a} ->
      {v, a} = substitute(v, table, opts, a)
      {Map.put(m, k, v), a}
    end)
  end

  # The CURRENT value of one reference, on the viewer's plane.
  defp lookup(%Ref{resource: name, pk: pk, attribute: attribute}, table, opts) do
    case Map.get(table, name) do
      {:ok, mod, records} ->
        with {:ok, field} <- ref_attribute(mod, attribute),
             {:ok, record} <- fetch_record(records, pk) do
          value(Map.get(record, field), pk, opts)
        else
          :code_changed -> {Placeholder.new(:code_changed), :code_changed}
          :gone -> {Placeholder.new(:gone), :gone}
        end

      _ ->
        {Placeholder.new(:code_changed), :code_changed}
    end
  end

  defp fetch_record(records, pk) do
    case Map.fetch(records, normalize_pk(pk)) do
      {:ok, record} -> {:ok, record}
      :error -> :gone
    end
  end

  # The stored attribute must STILL be one the recorder records by reference: a vault-routed
  # attribute (or a cleared metadata column). Matched as a string — no atom is created.
  defp ref_attribute(mod, attribute) when is_binary(attribute) do
    vault = mod |> Samen.Pii.Info.pii_attributes() |> Enum.map(& &1.name)

    plan =
      for {name, :ref} <- Samen.Replay.Sanitizer.plan(mod).attributes, do: name

    case Enum.find(vault ++ plan, &(Atom.to_string(&1) == attribute)) do
      nil -> :code_changed
      field -> {:ok, field}
    end
  rescue
    _ -> :code_changed
  end

  defp ref_attribute(_mod, _attribute), do: :code_changed

  defp value(%Masked{}, pk, _opts) do
    if shredded?(pk),
      do: {Placeholder.new(:shredded), :shredded},
      else: {Placeholder.new(:masked), :masked}
  end

  defp value(%Ash.ForbiddenField{}, pk, opts), do: value(%Masked{token: nil, label: nil}, pk, opts)
  defp value(%Ash.NotLoaded{}, _pk, _opts), do: {Placeholder.new(:code_changed), :code_changed}
  defp value(nil, _pk, _opts), do: {nil, :empty}
  defp value(plaintext, _pk, _opts), do: {plaintext, :clear}

  # The subject of a vault field is its record's primary key (`Samen.Vault.Change`). A value
  # that did not resolve to plaintext is `:shredded` when the KMS attests the subject's key is
  # destroyed — erasure reaches every stored replay with no replay-specific deletion.
  # A KMS that cannot attest never claims `:shredded` (the value stays `••••`). The record was
  # found by this pk, so it is never nil here.
  defp shredded?(pk) do
    match?({:ok, %{state: :shredded}}, Samen.Kms.adapter().attest(to_string(normalize_pk(pk))))
  rescue
    _ -> false
  end

  # A walked struct or an Ash record: the CURRENT module's struct with the captured fields
  # (atom keys only). Only what the recorder itself writes as a `$record` is rebuilt — an Ash
  # resource, or a struct on the sanitizer's walk-list. A stored row naming any other module
  # (a `Range` a template would loop over, a LiveView `Rendered`/`Comprehension` that renders
  # raw) is `:code_changed`, as is an unknown module: a row never picks the code path.
  defp build_struct(name, fields) do
    with mod when not is_nil(mod) <- Decoder.module(name),
         true <- function_exported?(mod, :__struct__, 0),
         false <- mod in @deny_structs,
         true <- Ash.Resource.Info.resource?(mod) or mod in Sanitizer.walk_structs() do
      struct(mod, Enum.filter(fields, fn {k, _v} -> is_atom(k) end))
    else
      _ -> Placeholder.new(:code_changed)
    end
  rescue
    _ -> Placeholder.new(:code_changed)
  end

  # A dropped struct → that module's DEFAULT struct (its defaults are code, never data) so a
  # template that reads `@list_state.filter` still renders; anything else dropped → nil.
  defp dropped(%Dropped{kind: :struct, struct: name}) when is_binary(name) do
    with mod when not is_nil(mod) <- Decoder.module(name),
         true <- function_exported?(mod, :__struct__, 0),
         false <- mod in @deny_structs,
         false <- Ash.Resource.Info.resource?(mod) do
      struct(mod)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp dropped(_), do: nil

  defp normalize_pk(pk) when is_binary(pk), do: String.downcase(pk)
  defp normalize_pk(pk), do: pk

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp short(name) when is_binary(name), do: name |> String.split(".") |> List.last()
  defp short(_), do: nil
end
