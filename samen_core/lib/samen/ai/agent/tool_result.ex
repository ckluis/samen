defmodule Samen.AI.Agent.ToolResult do
  @moduledoc """
  The EG2 tool-result renderer (ADR-047 §4.3 step 2, batch A3) — the ONE site that
  turns a governed action's outcome (and the model's own tool-call echo) into the
  **ordered list of plain binaries** that re-enters the prompt as `:history`.

  ## The scrub points, as implemented (each numbered point is an assertion site)

    * **Egress-mode resolution.** Any records the result carries resolve through
      `Samen.Api.PiiResolution.resolve/4` with `egress: true, grant_egress?: false`
      (§4.4 — agent runs are masked-only categorically): a vault-routed field comes
      back `%Samen.Masked{}` on EVERY plane and renders `••••`. Sabotage 248 drops
      the egress flag and the tenant plane would resolve PLAINTEXT — the named
      masking red test flips.
    * **`render_value/1` semantics, reused not re-derived** (the chokepoint's rule):
      `%Samen.Masked{}` → `••••`, `%Ash.ForbiddenField{}` → `••••`, `nil` → `••••`.
    * **Never `inspect/1`.** Anything the renderer does not recognize is dropped
      with a bounded `[unrenderable:<key>]` marker — an `inspect` here would be the
      freeform-text leak `Samen.Automation.RunRecord.bounded_outcomes/1` exists to
      prevent. Sabotage 247 returns the raw meta instead of rendered binaries and
      the chokepoint's `safe_segment?/1` allowlist REFUSES the next turn fail-closed
      (`:pii_egress_refused`) — the renderer is defense; the allowlist is the
      guarantee (§4.3#5, belt-and-braces).
    * **The call echo** (§4.3#6): the model's tool call (kind + args) re-enters as
      ONE rendered binary via `render_call/2` — never the raw arg map (the exact
      hole shipped sabotage 45 documents, re-proven on the agent path at A3).

  Mask-by-omission composes on top: `fetch_record` projects to condition-eligible
  fields only, so a plaintext-PII freeform column is not even present to render —
  and the vault-routed fields that ARE present render masked.
  """

  alias Samen.Api.PiiResolution

  @mask Samen.Masked.mask()
  @max_scalar_bytes 500
  @max_lines 60

  @doc """
  Render the model's own tool call (kind + validated args) to a single bounded
  binary for transcript/history re-entry — NEVER the raw arg map (§4.3#6).
  """
  @spec render_call(String.t(), map()) :: String.t()
  def render_call(kind, args) when is_binary(kind) and is_map(args) do
    rendered_args =
      args
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{render_scalar(v, to_string(k))}" end)

    String.trim("tool_call: #{kind} #{rendered_args}")
  end

  @doc """
  Render a governed action's outcome to the ordered list of plain binaries that
  re-enters the prompt as `:history` (§4.3 step 2).

  `opts`:
    * `:actor` — the run owner's actor map, threaded to `PiiResolution.resolve/4`
      (egress mode; REQUIRED for a record-bearing result).

  A `{:error, kind}` outcome renders as ONE bounded `tool_error:` line — the honest
  refusal the model sees (never a silent skip, never a rich term).
  """
  @spec render({:ok, map()} | {:error, term()}, keyword()) :: [String.t()]
  def render({:ok, meta}, opts) when is_map(meta) do
    meta
    |> render_meta(opts)
    |> Enum.take(@max_lines)
  end

  def render({:ok, _other}, _opts), do: ["tool_result: [unrenderable]"]

  def render({:error, kind}, _opts), do: ["tool_error: " <> bounded_kind(kind)]

  def render(_other, _opts), do: ["tool_error: tool_failed"]

  # --- meta rendering --------------------------------------------------------------------

  defp render_meta(meta, opts) do
    {records, meta} = pop(meta, :records)
    {resource_mod, meta} = pop(meta, :resource_module)
    {fields, meta} = pop(meta, :fields)
    {hits, meta} = pop(meta, :hits)

    scalar_lines =
      meta
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{render_scalar(v, to_string(k))}" end)

    scalar_lines ++
      render_hits(hits) ++
      render_records(records, resource_mod, fields, opts)
  end

  defp pop(meta, key) do
    {value, rest} = Map.pop(meta, key)

    case value do
      nil -> Map.pop(rest, to_string(key))
      _ -> {value, rest}
    end
  end

  # --- search hits (already masking-safe bounded maps) -----------------------------------

  defp render_hits(nil), do: []

  defp render_hits(hits) when is_list(hits) do
    Enum.map(hits, fn
      hit when is_map(hit) and not is_struct(hit) ->
        rendered =
          hit
          |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
          |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{render_hit_value(v, to_string(k))}" end)

        "hit: " <> rendered

      _other ->
        "hit: [unrenderable]"
    end)
  end

  defp render_hits(_), do: ["hits: [unrenderable]"]

  # A hit's "display" is itself a bounded map of registered non-PII scalars.
  defp render_hit_value(v, _key) when is_map(v) and not is_struct(v) do
    v
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(",", fn {k, val} -> "#{k}:#{render_scalar(val, to_string(k))}" end)
  end

  defp render_hit_value(v, key), do: render_scalar(v, key)

  # --- records (the §4.3 step-2 resolve + render) ----------------------------------------

  defp render_records(nil, _resource_mod, _fields, _opts), do: []

  defp render_records(records, resource_mod, fields, opts)
       when is_list(records) and is_atom(resource_mod) and not is_nil(resource_mod) do
    actor = Keyword.get(opts, :actor)
    pii_fields = pii_names(resource_mod)
    eligible = List.wrap(fields) |> Enum.reject(&(&1 in [:id, "id"]))

    # THE load-bearing call (§4.3 step 2 / §4.4): egress mode + grant egress OFF,
    # explicitly — a live reveal grant and grant_plaintext_egress: true can never
    # admit plaintext into an agent tool result (operator decision §9#2 TAKEN).
    resolved =
      PiiResolution.resolve(records, resource_mod, actor,
        egress: true,
        grant_egress?: false,
        repo: repo_of(resource_mod)
      )

    Enum.flat_map(resolved, fn record ->
      header = "record: #{inspect(resource_mod)}##{Map.get(record, :id)}"

      value_lines =
        Enum.map(eligible, fn field ->
          "#{field}: #{render_field(Map.get(record, field), to_string(field))}"
        end)

      pii_lines =
        Enum.map(pii_fields, fn field ->
          "#{field}: #{render_field(Map.get(record, field), to_string(field))}"
        end)

      [header | value_lines ++ pii_lines]
    end)
  rescue
    # A renderer crash must degrade to a bounded marker, never leak a term (EG6) —
    # and the chokepoint allowlist remains the last line regardless.
    _ -> ["tool_result: [unrenderable]"]
  end

  defp render_records(_records, _resource_mod, _fields, _opts), do: ["tool_result: [unrenderable]"]

  # The chokepoint's render_value/1 semantics, reused: masked/forbidden/nil → ••••.
  defp render_field(%Samen.Masked{}, _key), do: @mask
  defp render_field(%Ash.ForbiddenField{}, _key), do: @mask
  defp render_field(nil, _key), do: @mask
  defp render_field(value, key), do: render_scalar(value, key)

  # --- scalars ---------------------------------------------------------------------------

  # Bounded scalar rendering: binaries (truncated), numbers, booleans, atoms, and
  # date/times render; EVERYTHING else — a struct, a nested rich term, a pid — is
  # dropped with the bounded marker, never inspect-ed.
  defp render_scalar(v, _key) when is_binary(v), do: truncate(v)
  defp render_scalar(v, _key) when is_number(v), do: to_string(v)
  defp render_scalar(v, _key) when is_boolean(v), do: to_string(v)
  defp render_scalar(v, _key) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp render_scalar(%DateTime{} = v, _key), do: DateTime.to_iso8601(v)
  defp render_scalar(%NaiveDateTime{} = v, _key), do: NaiveDateTime.to_iso8601(v)
  defp render_scalar(%Date{} = v, _key), do: Date.to_iso8601(v)
  defp render_scalar(_v, key), do: "[unrenderable:#{key}]"

  defp truncate(v) when byte_size(v) <= @max_scalar_bytes, do: v
  defp truncate(v), do: String.slice(v, 0, @max_scalar_bytes)

  defp bounded_kind(kind) when is_atom(kind) and not is_nil(kind),
    do: kind |> Atom.to_string() |> truncate()

  defp bounded_kind(_kind), do: "tool_failed"

  defp pii_names(resource_mod) do
    resource_mod |> Samen.Pii.Info.pii_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp repo_of(resource_mod) do
    AshPostgres.DataLayer.Info.repo(resource_mod, :read)
  rescue
    _ -> Application.get_env(:samen_core, :vault_repo)
  end
end
