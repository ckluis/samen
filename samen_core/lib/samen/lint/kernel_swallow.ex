defmodule Samen.Lint.KernelSwallow do
  @moduledoc """
  The SWALLOW ratchet over the kernel (`samen_core/lib`) — the configuration half; the scanner is
  `Samen.Lint.Swallow` (shared with `Samen.Web.Reads.SwallowLint`, which configures it for samen_web,
  driftwood and pawchart).

  The kernel is web-dependency-free, so its ratchet lives here and runs in samen_core's own suite.

  Two ratchets, each with its OWN shrink-only baseline (exact match: more fails, fewer fails until lowered):

    * `baseline/0` — catch-all (or typed, literal-returning) `rescue` / `catch` clauses that neither log, report,
      re-raise nor hand the exception on (the original swallow);
    * `error_arm_baseline/0` — the non-rescue form: `{:error, _} -> <swallow literal>` (and `_ ->` over an I/O
      scrutinee) in a function that calls an Ash / Ecto / Repo read or write, directly or through a local def.

  Each baseline also has a HARD CEILING (`ceilings/0`): the committed total its rows must sum to, which a PR cannot
  raise without a visible, separately-tested edit (see `Samen.Lint.Swallow.check_ceiling/3`).

  A site that is genuinely total is a `reviewed/0` entry: `{file, function} => {count, hash, reason}`, pinned to the
  number AND the normalised source (hash) of the swallowing clauses in that function, with a reason that is
  literally true. Never a bare entry, never an unpinned one. A swallow added to — or a clause replaced in — a
  reviewed function fails the ratchet. `Samen.Lint.Swallow.reviewed_hash/5` computes the hash.

  Kernel failures are reported through `Samen.Observability.Failure` (value-free: name + exception module).
  """

  alias Samen.Lint.Swallow

  @roots ["samen_core/lib"]

  @reviewed %{
    {"samen_core/lib/samen/ai/chokepoint.ex", :charlist_sentinel?} =>
      {1, "0b17c23d9eddf284",
       "List.to_string/1 raises only for a list that is not chardata; a vt sentinel is a UTF-8 binary and can only be spelled by valid chardata, so for such a list `false` (no sentinel) is the exact answer — the element-wise allowlist (`safe_segment?/1`) still applies to it"},
    {"samen_core/lib/samen/ai.ex", :resolved_env} =>
      {1, "6e5f8d3527e06c4e",
       "fail-SECURE: an environment that cannot be resolved reads as :prod, the posture that refuses simulated providers and unconfigured adapters — never the permissive :dev/:test"},
    {"samen_core/lib/samen/kms.ex", :resolved_env} =>
      {1, "4f80883edc8535bc",
       "fail-SECURE: an environment that cannot be resolved reads as :prod, the posture that refuses an unimplemented skeleton adapter — never the permissive :dev/:test"},
    {"samen_core/lib/samen/fleet/crypto.ex", :verify_ed25519} =>
      {1, "3edb3c5dd1080096",
       ":crypto.verify raises for a malformed public key or signature (wrong size/type); a signature that cannot be verified is not valid, so `false` (reject) is the exact answer, never an accept"},
    {"samen_core/lib/samen/observability/failure.ex", :report} =>
      {1, "5effab65c1a31e95",
       "the failure reporter itself: observability must never break the operation it observes, and a reporter that raised would turn every handled failure into a crash — the clause is the last line, there is nothing left to report to"},
    {"samen_core/lib/samen/observability/failure.ex", :emit} =>
      {1, "15b438c33ee4efe2", "best-effort telemetry: observability must never break the read or write it observes"}
  }

  @baseline %{
    "samen_core/lib/mix/tasks/samen.doctor.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.agent_coverage.ex" => 4,
    "samen_core/lib/mix/tasks/samen.verify.ai_prompt_masking.ex" => 2,
    "samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.pii_classify.ex" => 2,
    "samen_core/lib/mix/tasks/samen.verify.prefixes.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.tool_actor_identity.ex" => 1,
    "samen_core/lib/samen/adapter_conformance_case.ex" => 6,
    "samen_core/lib/samen/aggregate/extension.ex" => 2,
    "samen_core/lib/samen/aggregate/query_budget.ex" => 1,
    "samen_core/lib/samen/ai.ex" => 1,
    "samen_core/lib/samen/ai/agent.ex" => 2,
    "samen_core/lib/samen/ai/agent/health.ex" => 4,
    "samen_core/lib/samen/ai/catalog.ex" => 5,
    "samen_core/lib/samen/ai/crm.ex" => 1,
    "samen_core/lib/samen/ai/embeddings.ex" => 3,
    "samen_core/lib/samen/ai/mcp.ex" => 3,
    "samen_core/lib/samen/ai/support_operator.ex" => 1,
    "samen_core/lib/samen/ai/tool_surface.ex" => 1,
    "samen_core/lib/samen/analytics.ex" => 1,
    "samen_core/lib/samen/analytics/sources.ex" => 1,
    "samen_core/lib/samen/api/pii_resolution.ex" => 4,
    "samen_core/lib/samen/api_contract.ex" => 3,
    "samen_core/lib/samen/approvals.ex" => 1,
    "samen_core/lib/samen/auth/org_actor.ex" => 2,
    "samen_core/lib/samen/automation/action.ex" => 2,
    "samen_core/lib/samen/automation/actions/assign_record_owner.ex" => 3,
    "samen_core/lib/samen/automation/actions/fetch_record.ex" => 3,
    "samen_core/lib/samen/automation/actions/search_records.ex" => 2,
    "samen_core/lib/samen/automation/actions/support.ex" => 2,
    "samen_core/lib/samen/automation/actions/webhook.ex" => 1,
    "samen_core/lib/samen/automation/compile.ex" => 1,
    "samen_core/lib/samen/automation/dispatch_worker.ex" => 1,
    "samen_core/lib/samen/automation/escalate.ex" => 1,
    "samen_core/lib/samen/automation/escalation_advance.ex" => 1,
    "samen_core/lib/samen/automation/event_capture.ex" => 2,
    "samen_core/lib/samen/automation/health.ex" => 3,
    "samen_core/lib/samen/automation/non_pii_predicates.ex" => 1,
    "samen_core/lib/samen/automation/remind.ex" => 1,
    "samen_core/lib/samen/automation/reminder_fire.ex" => 1,
    "samen_core/lib/samen/automation/run_record.ex" => 2,
    "samen_core/lib/samen/automation/run_worker.ex" => 2,
    "samen_core/lib/samen/automation/schedule_advance.ex" => 1,
    "samen_core/lib/samen/backup/verification.ex" => 1,
    "samen_core/lib/samen/billing/ash_checkout_mirror.ex" => 1,
    "samen_core/lib/samen/billing/dunning.ex" => 3,
    "samen_core/lib/samen/billing/movement_backfill.ex" => 5,
    "samen_core/lib/samen/billing/subscription_movement.ex" => 6,
    "samen_core/lib/samen/billing/webhook_dispatch.ex" => 2,
    "samen_core/lib/samen/catalog.ex" => 2,
    "samen_core/lib/samen/cdc/projection.ex" => 3,
    "samen_core/lib/samen/clone.ex" => 1,
    "samen_core/lib/samen/context/info.ex" => 1,
    "samen_core/lib/samen/context/transformers/no_storage.ex" => 1,
    "samen_core/lib/samen/crm/account_link.ex" => 2,
    "samen_core/lib/samen/custom_fields/change.ex" => 1,
    "samen_core/lib/samen/data_map.ex" => 1,
    "samen_core/lib/samen/delivery/marketing_receipt_lookup.ex" => 1,
    "samen_core/lib/samen/delivery/provider_conformance_case.ex" => 2,
    "samen_core/lib/samen/delivery/throttle.ex" => 2,
    "samen_core/lib/samen/delivery/webhook_dispatch.ex" => 1,
    "samen_core/lib/samen/feature_flags.ex" => 1,
    "samen_core/lib/samen/feature_flags/cache.ex" => 1,
    "samen_core/lib/samen/files.ex" => 1,
    "samen_core/lib/samen/fleet/attention.ex" => 1,
    "samen_core/lib/samen/fleet/nonce_cache.ex" => 1,
    "samen_core/lib/samen/fleet/registry.ex" => 1,
    "samen_core/lib/samen/fleet/report/schema.ex" => 1,
    "samen_core/lib/samen/gen/app.ex" => 1,
    "samen_core/lib/samen/jobs/queue_parity.ex" => 1,
    "samen_core/lib/samen/mailbox/match.ex" => 3,
    "samen_core/lib/samen/mailbox/sync.ex" => 1,
    "samen_core/lib/samen/marketing/consent_change.ex" => 2,
    "samen_core/lib/samen/metrics.ex" => 1,
    "samen_core/lib/samen/metrics/contention_handlers.ex" => 1,
    "samen_core/lib/samen/migration.ex" => 1,
    "samen_core/lib/samen/migration/expand_contract.ex" => 1,
    "samen_core/lib/samen/no_plaintext_pii.ex" => 1,
    "samen_core/lib/samen/no_plaintext_pii/context.ex" => 4,
    "samen_core/lib/samen/no_plaintext_pii/tiers/log_telemetry.ex" => 1,
    "samen_core/lib/samen/no_plaintext_pii/tiers/vault_declarations.ex" => 1,
    "samen_core/lib/samen/notifications/engine.ex" => 1,
    "samen_core/lib/samen/notifications/status_change.ex" => 2,
    "samen_core/lib/samen/observability/job_spans.ex" => 4,
    "samen_core/lib/samen/observability/live_events.ex" => 2,
    "samen_core/lib/samen/observability/live_telemetry.ex" => 4,
    "samen_core/lib/samen/observability/param_filter.ex" => 2,
    "samen_core/lib/samen/pii/classification.ex" => 1,
    "samen_core/lib/samen/pii/info.ex" => 2,
    "samen_core/lib/samen/pii_classify.ex" => 1,
    "samen_core/lib/samen/replay.ex" => 2,
    "samen_core/lib/samen/replay/buffer.ex" => 7,
    "samen_core/lib/samen/replay/capture.ex" => 6,
    "samen_core/lib/samen/replay/decoder.ex" => 2,
    "samen_core/lib/samen/replay/frame_schema.ex" => 1,
    "samen_core/lib/samen/replay/monitor.ex" => 1,
    "samen_core/lib/samen/replay/player.ex" => 3,
    "samen_core/lib/samen/replay/resolver.ex" => 9,
    "samen_core/lib/samen/replay/row_guard.ex" => 1,
    "samen_core/lib/samen/replay/sanitizer.ex" => 3,
    "samen_core/lib/samen/reveal/grants.ex" => 2,
    "samen_core/lib/samen/scopes/identity/notify.ex" => 1,
    "samen_core/lib/samen/scopes/marketing/blueprint.ex" => 2,
    "samen_core/lib/samen/scopes/marketing/send_worker.ex" => 1,
    "samen_core/lib/samen/scopes/support/sla_breach_worker.ex" => 1,
    "samen_core/lib/samen/search.ex" => 3,
    "samen_core/lib/samen/sequences.ex" => 1,
    "samen_core/lib/samen/sequences/receipt_lookup.ex" => 1,
    "samen_core/lib/samen/test_sandbox.ex" => 1,
    "samen_core/lib/samen/tracer.ex" => 3,
    "samen_core/lib/samen/transformers/materialize_pii.ex" => 1,
    "samen_core/lib/samen/versioning/select_for_version.ex" => 1,
    "samen_core/lib/samen/webhook/delivery_worker.ex" => 2,
    "samen_core/lib/samen/webhook/event.ex" => 1,
    "samen_core/lib/samen/webhook/ingest_worker.ex" => 2,
    "samen_core/lib/samen/webhook/payload.ex" => 3
  }

  @error_arm_baseline %{
    "samen_core/lib/samen/ai/agent.ex" => 1,
    "samen_core/lib/samen/ai/agent/breaker.ex" => 1,
    "samen_core/lib/samen/ai/agent/fold_source.ex" => 1,
    "samen_core/lib/samen/ai/embeddings.ex" => 2,
    "samen_core/lib/samen/approvals.ex" => 1,
    "samen_core/lib/samen/automation/actions/record_family.ex" => 1,
    "samen_core/lib/samen/billing/subscription_movement.ex" => 1,
    "samen_core/lib/samen/custom_objects.ex" => 1,
    "samen_core/lib/samen/fleet/registry.ex" => 3,
    "samen_core/lib/samen/identity/invite.ex" => 1,
    "samen_core/lib/samen/non_pii.ex" => 1,
    "samen_core/lib/samen/operator_plane.ex" => 3,
    "samen_core/lib/samen/replay/resolver.ex" => 1,
    "samen_core/lib/samen/reveal/grants.ex" => 1,
    "samen_core/lib/samen/scopes/marketing/blueprint.ex" => 2,
    "samen_core/lib/samen/sequences/receipt_lookup.ex" => 1,
    "samen_core/lib/samen/support/inbound/ingest.ex" => 2,
    "samen_core/lib/samen/support/inbound/threading.ex" => 2
  }

  # The HARD CEILING per class and root: the baseline above must sum to exactly this. A PR that raises a baseline row
  # has to raise this number too (and `SwallowLintTest` compares it with the merge base, so it can only go down). Lower
  # it together with the baseline when a swallow is converted; never raise it.
  @ceilings %{
    rescue: %{"samen_core/lib" => 227},
    error_arm: %{"samen_core/lib" => 26}
  }

  def roots, do: @roots
  def baseline, do: @baseline
  def error_arm_baseline, do: @error_arm_baseline
  def reviewed, do: @reviewed
  def ceilings, do: @ceilings

  @doc "Repo root, anchored on this file's compile-time path (cwd-independent)."
  def repo_root, do: __ENV__.file |> Path.dirname() |> Path.join("../../../..") |> Path.expand()

  @doc "Every `.ex` file under the kernel root, as repo-relative paths."
  def files, do: Swallow.files(repo_root(), @roots)

  @doc "Unreviewed rescue-class swallow count per file."
  def scan(files \\ files()), do: Swallow.scan(repo_root(), files, @reviewed, :rescue)

  @doc "Non-rescue (`{:error, _} -> literal`) site count per file."
  def scan_error_arms(files \\ files()), do: Swallow.scan(repo_root(), files, %{}, :error_arm)

  def scan_source(source, file \\ "nofile", class \\ :rescue), do: Swallow.scan_source(source, file, class)

  @doc "`:ok` or `{:error, [message]}` for the rescue class."
  def check(counts \\ scan(), baseline \\ @baseline),
    do:
      Swallow.check(
        counts,
        baseline,
        "report it through Samen.Observability.Failure.report/3 and return a tagged {:error, :unavailable} " <>
          "(or log/re-raise); do NOT raise the baseline"
      )

  @doc "`:ok` or `{:error, [message]}` for the non-rescue class."
  def check_error_arms(counts \\ scan_error_arms(), baseline \\ @error_arm_baseline),
    do:
      Swallow.check(
        counts,
        baseline,
        "return a tagged {:error, :unavailable} (or the error itself) instead of a literal empty value; do NOT raise the baseline"
      )

  @doc "`:ok` or `{:error, [message]}`: each baseline sums to its committed ceiling (see `ceilings/0`)."
  def check_ceilings do
    with :ok <- Swallow.check_ceiling(@baseline, @ceilings.rescue, @roots),
         :ok <- Swallow.check_ceiling(@error_arm_baseline, @ceilings.error_arm, @roots) do
      :ok
    end
  end

  @doc "Stale/inexact `reviewed/0` pins (`[]` when exact)."
  def reviewed_problems(files \\ files()), do: Swallow.reviewed_problems(repo_root(), files, @reviewed, :rescue)
end
