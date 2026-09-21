defmodule Samen.Automation.Definition do
  @moduledoc """
  The **pinned workflow definition** — one run's snapshot of the rule it executes
  (T162; ADR-039 §3.3/§8.1, ADR-040 §6 lineage).

  ## The bug this exists to close

  Before T162 the pipeline carried only `workflow_id` from enqueue to execution:
  `RunWorker` re-read the Workflow row at `perform` time and ran **whatever it read
  then**. A tenant edit landing between enqueue and execution (or between Oban
  retries of the same job) therefore changed what an ALREADY-TRIGGERED run executed,
  and a historical `Automation.Run` row could not be interpreted against the
  definition that actually ran — only against whatever the rule happens to say today.

  ## The pin shape (decided; snapshot, content-addressed)

  `Samen.Automation.DispatchWorker` — the ONE stamping point, holding the workflow it
  just matched — stamps the **full definition snapshot** plus its **content digest**
  into the `RunWorker` job args at enqueue. `Samen.Automation.RunRecord` copies both
  onto the `Automation.Run` row it opens from those same args, so the row and the
  execution can never disagree about which definition ran: the row's pin is *derived
  from the job's pin*, not re-read from the live rule.

  The digest IS the version identity — content-addressed (`sha256` over a canonical
  encoding), so two runs of the same definition share a digest and any edit produces a
  different one, with no separate version table to keep in step and no backfill for
  rules that already exist. The immutable store the digest resolves against is the Run
  row itself: `run.definition` is the definition that ran, `run.definition_digest`
  names it. (ADR-040 §6.2's AshPaperTrail machinery versions a resource's EDIT
  HISTORY; a version row exists only from the next tracked write onward, which is one
  deploy too late to interpret runs of rules that already exist, and Workflow's
  per-minute `:dispatch_due` schedule advance would amplify it into a version row a
  minute per scheduled rule. Enrolling Workflow in §6.2 remains an orthogonal,
  complementary follow-up for edit history — it is NOT the pin.)

  ## What is pinned, and what stays LIVE (ADR-039 §8.4, binding)

  Pinned (what the run EXECUTES): `actions` (fed to `Samen.Automation.Compile`),
  `conditions` (the §4.4 AND-gate) and `resource_key` (which resource the subject is
  re-read from).

  **Never pinned** — re-read live on every attempt, exactly as before: the two
  kill-switches (`status`, `disabled_by_operator_at` — the §8.4 double-check), the
  owner (`owner_id`, §4.5) and the org. A paused, killed, or owner-less workflow must
  still skip even when its definition is pinned; a pinned-but-still-executing run of a
  paused rule would be a strictly worse bug than the one this module fixes. The
  SUBJECT is also still re-read live and governed (§3.3) — the pin is the RULE, never
  subject data.

  Also never pinned, for a different reason: `webhook_secret` (§5.3). It is credential
  material, not definition — snapshotting it would copy a secret into `oban_jobs.args`
  and onto every Run row, and a rotated secret must take effect on the next attempt.
  `RunWorker` keeps reading it from the live row into the fire-time `Context`.

  ## Non-PII by schema (INV-1; ADR-039 §13 untouched)

  The snapshot is a byte-copy of `Workflow.conditions` / `Workflow.actions` plus the
  catalog `resource_key` — three columns that are already non-PII BY SCHEMA and stay
  that way by an enforced write-time refusal, not by convention:

    * every `conditions[*].attribute` and every `{{subject.<attr>}}` interpolation
      inside an action config must pass `Samen.Automation.NonPiiPredicates` at the
      Workflow WRITE — a vault-routed or plaintext-PII attribute is structurally
      unreferenceable (INV-1);
    * action configs carry selectors and framework copy keys, never subject values —
      ADR-039 §13 explicitly REJECTS freeform to-addresses for exactly this reason;
    * `resource_key` is a catalog module identity, not data.

  So pinning adds **no new PII surface**: it copies already-governed structure. In
  particular it is NOT the "snapshot-based undo for update actions" that ADR-039 §13
  rejects — that rejection is about persisting prior SUBJECT ATTRIBUTE VALUES. No
  subject value is in a definition, so INV-1's undo-snapshot refusal is untouched.

  ## Unpinned jobs (the one-deploy transition window)

  A `RunWorker` job enqueued by the PREVIOUS release, or enqueued directly by a caller
  that is not `DispatchWorker` (tests do this to exercise the already-queued half of
  the kill-switch), carries no pin. `resolve/2` then falls back to the live rule and
  says so in the log — the pre-T162 behaviour, for jobs that never got a pin, rather
  than dropping legitimate queued work on deploy. Every job enqueued by this release
  carries one.
  """

  require Logger

  @pin_key "definition"
  @digest_key "definition_digest"

  @doc "The job-args / Run-row key carrying the pinned definition map."
  @spec pin_key() :: String.t()
  def pin_key, do: @pin_key

  @doc "The job-args / Run-row key carrying the pinned definition's content digest."
  @spec digest_key() :: String.t()
  def digest_key, do: @digest_key

  @doc """
  The definition snapshot of a workflow: the three fields a run EXECUTES, normalized
  to JSON-stable form (string keys, atoms as strings) so the map that travels through
  Oban args and jsonb is byte-identical to the one the digest was taken over.
  """
  @spec snapshot(map()) :: map()
  def snapshot(wf) do
    %{
      "actions" => normalize(field(wf, :actions, [])),
      "conditions" => normalize(field(wf, :conditions, [])),
      "resource_key" => normalize(field(wf, :resource_key, nil))
    }
  end

  @doc """
  The content digest of a definition map — `sha256` over a canonical encoding (map
  keys sorted, atoms as strings), hex. Stable across the Oban-args and jsonb
  round-trips, so `digest(run.definition) == run.definition_digest` holds when the row
  is read back.
  """
  @spec digest(map()) :: String.t()
  def digest(definition) when is_map(definition) do
    :crypto.hash(:sha256, canonical(normalize(definition)))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Stamp the pin onto a dispatch-envelope map: the definition snapshot + its digest,
  taken from the workflow the caller has ALREADY matched. The only place a pin is
  minted (`Samen.Automation.DispatchWorker`).
  """
  @spec put_pin(map(), map()) :: map()
  def put_pin(args, wf) when is_map(args) do
    snap = snapshot(wf)

    args
    |> Map.put(@pin_key, snap)
    |> Map.put(@digest_key, digest(snap))
  end

  @doc """
  The definition this attempt must execute.

  Returns `{:pinned, definition}` when the job args carry a pin (every job enqueued by
  `DispatchWorker` since T162 — retries of the same job carry the SAME args, so a
  retry re-executes the same pin), or `{:unpinned, definition}` built from the live
  workflow for a pre-T162 / directly-enqueued job (logged).
  """
  @spec resolve(map(), map()) :: {:pinned | :unpinned, map()}
  def resolve(args, wf) when is_map(args) do
    case Map.get(args, @pin_key) do
      %{} = pinned ->
        {:pinned, normalize(pinned)}

      _ ->
        Logger.debug(
          "[Automation.Definition] no pinned definition in job args for workflow " <>
            "#{inspect(args["workflow_id"])} — executing the LIVE definition " <>
            "(pre-T162 job or a direct enqueue)"
        )

        {:unpinned, snapshot(wf)}
    end
  end

  @doc "The ordered action-config list of a definition (what `Compile.run/2` consumes)."
  @spec actions(map()) :: [map()]
  def actions(definition), do: definition |> Map.get("actions") |> List.wrap()

  @doc "The condition list of a definition (the §4.4 AND-gate)."
  @spec conditions(map()) :: [map()]
  def conditions(definition), do: definition |> Map.get("conditions") |> List.wrap()

  @doc "The catalog resource key of a definition (which resource the subject is re-read from)."
  @spec resource_key(map()) :: String.t() | nil
  def resource_key(definition), do: Map.get(definition, "resource_key")

  # ---------------------------------------------------------------------------

  # A `:map`/`{:array, :map}` attribute keeps whatever shape the caller cast (atom keys
  # survive in memory) while the SAME value comes back string-keyed through jsonb or
  # Oban args. Normalizing both sides is what makes the digest a stable identity rather
  # than an artifact of which side of the JSON boundary the map was read from.
  defp normalize(%Ash.NotLoaded{}), do: nil
  defp normalize(%_{} = struct), do: struct
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(nil), do: nil
  defp normalize(b) when is_boolean(b), do: b
  defp normalize(a) when is_atom(a), do: Atom.to_string(a)
  defp normalize(other), do: other

  # Canonical JSON: the SAME map must produce the same bytes regardless of key
  # insertion order (jsonb does not preserve it), so keys are sorted at every level.
  # `Jason.encode!/1` alone would not do that.
  defp canonical(m) when is_map(m) and not is_struct(m) do
    inner =
      m
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp canonical(l) when is_list(l) do
    ["[", l |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical(v), do: Jason.encode!(v)

  defp field(wf, key, default) do
    case Map.get(wf, key, default) do
      %Ash.NotLoaded{} -> default
      nil -> default
      val -> val
    end
  end
end
