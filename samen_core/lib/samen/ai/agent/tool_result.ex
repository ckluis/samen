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
    * **INGRESS neutralization (§4.3a, T182 — PROPOSED).** Every scrub point above
      faces OUTWARD; this one faces IN. A tool result is attacker-reachable data, and
      it re-enters the prompt as `:history` on the next turn — so before a binary is
      emitted it goes through `Samen.AI.Agent.Ingress.sanitize/1`, which neutralizes
      invisible/bidi/control characters and instruction-shaped text into one fixed,
      non-invertible marker. Both untrusted surfaces funnel through one clause each:
      values via `render_scalar/2`, model-emitted argument NAMES via `render_key/1`.
      Sabotage 289 keeps it refutable. This is a content transform inside the existing
      render chokepoint, deliberately NOT a second policy seam beside T181's hook chain
      (see `Samen.AI.Agent.Ingress`'s moduledoc for why the hook chain cannot host it).
    * **Secrets-redaction lane (§4.3b, T184 — PROPOSED), distinct from `pii_*`.** A
      THIRD content transform at the SAME two clauses: `Samen.AI.Agent.Secrets.redact/1`
      pattern-scans for operator/app API keys, tokens and credentialed connection
      strings appearing INCIDENTALLY in tool output — free text no `pii_*` vault
      declaration governs, so `PiiResolution` has nothing to key on. Runs BEFORE
      `Ingress.sanitize/1` (on the untouched raw binary, so ingress's own marker cannot
      first break the generic fallback's label/value adjacency); the vault-masking path
      above (`render_field/2`, egress-mode `PiiResolution.resolve/4`) is untouched.
      Sabotage 291 keeps it refutable; sabotage 255 regenerated (see `Secrets`'
      moduledoc for why the passes order this way).

  Mask-by-omission composes on top: `fetch_record` projects to condition-eligible
  fields only, so a plaintext-PII freeform column is not even present to render —
  and the vault-routed fields that ARE present render masked.

  ## Sentinel-bearing scalars: replaced per value, NOT escalated to a run failure (A4)

  A3 shipped this renderer NOT scanning for the `vt_` sentinel, leaning entirely on the
  chokepoint's `safe_segment?/1` last line. The A3 verifier confirmed the seam is real
  and named the consequence: a tenant who can get a `vt_`-looking string into an
  eligible column HARD-FAILS every agent run that touches that record
  (`:pii_egress_refused`), because the offending line kills the whole payload. That is a
  tenant-controlled denial-of-service on the agent plane — attacker-controlled DATA
  choosing the outcome of a governed run.

  The ADR settles the posture and it is not the fail-closed one. §4.3 step 2 makes
  `[unrenderable:<field>]` the renderer's general answer to "a value I cannot safely
  emit"; §4.3 step 3 asserts as a PROPERTY that "the transcript at rest contains no
  vault plaintext and **no `vt_*` token**"; and §4.3#6 says the echo "is rendered to a
  single **`vt_`-free binary** by the same renderer". A renderer that emits a `vt_`
  scalar violates all three. So a sentinel-bearing scalar (or map key) renders as the
  bounded `[unrenderable:<key>]` marker — the SAME marker every other unrenderable value
  gets — and the run proceeds honestly with that one value elided.

  This does not weaken the last line: `safe_segment?/1` still refuses any `vt_`-bearing
  binary the renderer might ever emit, and the belt-and-braces §4.3#5 property (a
  renderer regression that emits raw shapes REFUSES fail-closed) is untouched — sabotage
  247 still proves it. What changed is only that the normal path stopped routing
  tenant data through the emergency exit. Sabotage 255 keeps the replacement refutable.
  """

  alias Samen.AI.Agent.Ingress
  alias Samen.AI.Agent.Secrets
  alias Samen.Api.PiiResolution

  @mask Samen.Masked.mask()
  @max_scalar_bytes 500
  @max_lines 60

  # The vault FK-token sentinel (ADR-043 §3.1 INV-7). See `render_scalar/2` and the
  # "sentinel-bearing scalars" section of the moduledoc.
  @vt_sentinel "vt_"

  @doc """
  Render the model's own tool call (kind + validated args) to a single bounded
  binary for transcript/history re-entry — NEVER the raw arg map (§4.3#6).
  """
  @spec render_call(String.t(), map()) :: String.t()
  def render_call(kind, args) when is_binary(kind) and is_map(args) do
    rendered_args =
      args
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{render_key(k)}=#{render_scalar(v, to_string(k))}" end)

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
      |> Enum.map(fn {k, v} -> "#{render_key(k)}: #{render_scalar(v, to_string(k))}" end)

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
          |> Enum.map_join(" ", fn {k, v} -> "#{render_key(k)}=#{render_hit_value(v, to_string(k))}" end)

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
    |> Enum.map_join(",", fn {k, val} -> "#{render_key(k)}:#{render_scalar(val, to_string(k))}" end)
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
      # A5 (the A4 verifier's R7): the primary key goes through `render_scalar/2` like
      # every other value. It was the ONE interpolation site that did not, which is
      # structurally moot for a uuid pk but would have been a sentinel path around the
      # A4 elision fold for a host resource with a string pk.
      header = "record: #{inspect(resource_mod)}##{render_scalar(Map.get(record, :id), "id")}"

      value_lines =
        Enum.map(eligible, fn field ->
          "#{render_key(field)}: #{render_field(Map.get(record, field), to_string(field))}"
        end)

      pii_lines =
        Enum.map(pii_fields, fn field ->
          "#{render_key(field)}: #{render_field(Map.get(record, field), to_string(field))}"
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
  #
  # A4 (fold (c)): a scalar CARRYING the `vt_` vault-token sentinel is one more value
  # this renderer cannot safely emit, so it takes the same `[unrenderable:<key>]` exit
  # as any other. Per-VALUE, deliberately: escalating it to the chokepoint's whole-payload
  # refusal would let attacker-controlled data hard-fail a governed run (see moduledoc).
  # Truncation runs AFTER the scan, so a sentinel past the 500-byte boundary cannot be
  # "sanitised" by luck.
  #
  # T182 (§4.3a INGRESS, PROPOSED): the value is NEUTRALIZED before it is scanned and before
  # it is emitted — this clause is the ingress chokepoint for every untrusted binary that
  # becomes a `:history` line. Sanitizing FIRST is load-bearing twice over: the binary that
  # gets emitted is the binary that was scanned, and a `vt_` obfuscated with zero-width
  # characters cannot hide from the sentinel scan behind them. The RAW value is scanned too,
  # so the pre-T182 refusal is a floor this can only tighten, never move.
  #
  # T184 (§4.3b secrets lane, PROPOSED): `Secrets.redact/1` runs FIRST, on the untouched raw
  # binary, before `Ingress.sanitize/1` — a distinct lane from the `pii_*` vault taxonomy
  # above, catching operator/app API keys, tokens and connection strings that carry no
  # declared-field vault routing at all (see `Secrets`' moduledoc for the ordering rationale).
  defp render_scalar(v, key) when is_binary(v) do
    sanitized = v |> Secrets.redact() |> Ingress.sanitize()

    if sentinel?(v) or sentinel?(sanitized),
      do: unrenderable(key),
      else: truncate(sanitized)
  end

  defp render_scalar(v, _key) when is_number(v), do: to_string(v)
  defp render_scalar(v, _key) when is_boolean(v), do: to_string(v)

  defp render_scalar(v, key) when is_atom(v) and not is_nil(v) do
    rendered = Atom.to_string(v)
    if sentinel?(rendered), do: unrenderable(key), else: rendered
  end

  defp render_scalar(%DateTime{} = v, _key), do: DateTime.to_iso8601(v)
  defp render_scalar(%NaiveDateTime{} = v, _key), do: NaiveDateTime.to_iso8601(v)
  defp render_scalar(%Date{} = v, _key), do: Date.to_iso8601(v)
  defp render_scalar(_v, key), do: unrenderable(key)

  # The bounded marker. The KEY is authored/catalog-derived (a field or arg name), never
  # tenant free text — but it is scanned anyway, so no path can smuggle a sentinel out
  # through the marker itself.
  defp unrenderable(key) do
    key = to_string(key)
    if sentinel?(key), do: "[unrenderable]", else: "[unrenderable:#{key}]"
  end

  defp sentinel?(value) when is_binary(value), do: String.contains?(value, @vt_sentinel)
  defp sentinel?(_value), do: false

  # Every key this module interpolates into a line — a meta key, a record field name, a
  # search-hit key, a model-emitted ARG name. Field names are catalog-derived and arg
  # names are already `vt_`-gated upstream (`Samen.AI.Agent`'s `refuse_vt_args/1` scans
  # keys AND values), but `render_call/2` and `render/2` are PUBLIC — so the key side is
  # scanned here too rather than relying on every caller having done it.
  # T182: an arg name is MODEL output, so it is untrusted content on the ingress side too —
  # an arg name carrying a line break would forge a transcript line out of `render_call/2`'s
  # `k=v` join exactly as a value would. Same neutralization, same chokepoint discipline.
  # T184: same secrets lane, same ordering (redact before sanitize) — a model-emitted arg
  # name is untrusted content too and gets no exemption from the pattern scan.
  defp render_key(key) do
    rendered = key |> to_string() |> Secrets.redact() |> Ingress.sanitize()
    if sentinel?(rendered), do: "[key]", else: rendered
  end

  defp truncate(v) when byte_size(v) <= @max_scalar_bytes, do: v
  defp truncate(v), do: String.slice(v, 0, @max_scalar_bytes)

  defp bounded_kind(kind) when is_atom(kind) and not is_nil(kind) do
    rendered = Atom.to_string(kind)
    if sentinel?(rendered), do: "tool_failed", else: truncate(rendered)
  end

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
