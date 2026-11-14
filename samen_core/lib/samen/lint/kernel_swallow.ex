defmodule Samen.Lint.KernelSwallow do
  @moduledoc """
  The SWALLOW ratchet over the kernel (`samen_core/lib`) — the configuration half; the scanner is
  `Samen.Lint.Swallow` (shared with `Samen.Web.Reads.SwallowLint`, which configures it for samen_web,
  driftwood and pawchart).

  The kernel is web-dependency-free, so its ratchet lives here and runs in samen_core's own suite.

  Two ratchets, each with its OWN shrink-only baseline (exact match: more fails, fewer fails until lowered):

    * `baseline/0` — catch-all `rescue` / `catch` clauses that neither log, report, re-raise nor hand the
      exception on (the original swallow);
    * `error_arm_baseline/0` — the non-rescue form: `{:error, _} -> []/nil/0/false/:ok` in a function that
      calls an Ash / Ecto / Repo read or write.

  A site that is genuinely total is a `reviewed/0` entry: `{file, function} => {count, reason}`, pinned to the
  number of swallowing clauses in that function, with a reason that is literally true. Never a bare entry,
  never an unpinned one. A swallow added to a reviewed function fails the ratchet.

  Kernel failures are reported through `Samen.Observability.Failure` (value-free: name + exception module).
  """

  alias Samen.Lint.Swallow

  @roots ["samen_core/lib"]

  @reviewed %{
    {"samen_core/lib/samen/observability/failure.ex", :report} =>
      {1,
       "the failure reporter itself: observability must never break the operation it observes, and a reporter that raised would turn every handled failure into a crash — the clause is the last line, there is nothing left to report to"},
    {"samen_core/lib/samen/observability/failure.ex", :emit} =>
      {1, "best-effort telemetry: observability must never break the read or write it observes"}
  }

  @baseline %{
    "samen_core/lib/mix/tasks/samen.doctor.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.agent_coverage.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.ai_prompt_masking.ex" => 2,
    "samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.pii_classify.ex" => 2,
    "samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.tool_actor_identity.ex" => 1,
    "samen_core/lib/samen/adapter_conformance_case.ex" => 6,
    "samen_core/lib/samen/aggregate/extension.ex" => 2,
    "samen_core/lib/samen/aggregate/query_budget.ex" => 1,
    "samen_core/lib/samen/ai.ex" => 2,
    "samen_core/lib/samen/ai/agent.ex" => 9,
    "samen_core/lib/samen/ai/agent/approver.ex" => 3,
    "samen_core/lib/samen/ai/agent/breaker.ex" => 2,
    "samen_core/lib/samen/ai/agent/health.ex" => 4,
    "samen_core/lib/samen/ai/agent/hooks.ex" => 2,
    "samen_core/lib/samen/ai/agent/tool_result.ex" => 3,
    "samen_core/lib/samen/ai/agent/write_proposal.ex" => 1,
    "samen_core/lib/samen/ai/catalog.ex" => 6,
    "samen_core/lib/samen/ai/chokepoint.ex" => 15,
    "samen_core/lib/samen/ai/crm.ex" => 1,
    "samen_core/lib/samen/ai/embeddings.ex" => 3,
    "samen_core/lib/samen/ai/mcp.ex" => 4,
    "samen_core/lib/samen/ai/support_operator.ex" => 1,
    "samen_core/lib/samen/ai/tool_surface.ex" => 1,
    "samen_core/lib/samen/analytics.ex" => 1,
    "samen_core/lib/samen/analytics/sources.ex" => 1,
    "samen_core/lib/samen/api/pii_resolution.ex" => 4,
    "samen_core/lib/samen/api_contract.ex" => 3,
    "samen_core/lib/samen/approvals.ex" => 1,
    "samen_core/lib/samen/audit_chain.ex" => 1,
    "samen_core/lib/samen/audit_chain/writer.ex" => 1,
    "samen_core/lib/samen/automation/action.ex" => 2,
    "samen_core/lib/samen/automation/actions/assign_record_owner.ex" => 3,
    "samen_core/lib/samen/automation/actions/fetch_record.ex" => 2,
    "samen_core/lib/samen/automation/actions/search_records.ex" => 2,
    "samen_core/lib/samen/automation/actions/support.ex" => 1,
    "samen_core/lib/samen/automation/breaker.ex" => 1,
    "samen_core/lib/samen/automation/compile.ex" => 1,
    "samen_core/lib/samen/automation/escalate.ex" => 1,
    "samen_core/lib/samen/automation/escalation_advance.ex" => 1,
    "samen_core/lib/samen/automation/event_capture.ex" => 2,
    "samen_core/lib/samen/automation/health.ex" => 4,
    "samen_core/lib/samen/automation/non_pii_predicates.ex" => 1,
    "samen_core/lib/samen/automation/remind.ex" => 1,
    "samen_core/lib/samen/automation/reminder_fire.ex" => 1,
    "samen_core/lib/samen/automation/run_record.ex" => 2,
    "samen_core/lib/samen/automation/run_worker.ex" => 1,
    "samen_core/lib/samen/automation/schedule_advance.ex" => 1,
    "samen_core/lib/samen/backup/verification.ex" => 1,
    "samen_core/lib/samen/billing/dunning.ex" => 3,
    "samen_core/lib/samen/billing/movement_backfill.ex" => 5,
    "samen_core/lib/samen/billing/subscription_movement.ex" => 6,
    "samen_core/lib/samen/billing/webhook_dispatch.ex" => 1,
    "samen_core/lib/samen/break_glass/reconcile_worker.ex" => 2,
    "samen_core/lib/samen/break_glass/reconciliation.ex" => 2,
    "samen_core/lib/samen/catalog.ex" => 2,
    "samen_core/lib/samen/cdc/projection.ex" => 3,
    "samen_core/lib/samen/clone.ex" => 1,
    "samen_core/lib/samen/context/info.ex" => 1,
    "samen_core/lib/samen/context/transformers/no_storage.ex" => 1,
    "samen_core/lib/samen/crm/account_link.ex" => 2,
    "samen_core/lib/samen/custom_fields/change.ex" => 1,
    "samen_core/lib/samen/data_map.ex" => 1,
    "samen_core/lib/samen/delivery/deliverability.ex" => 2,
    "samen_core/lib/samen/delivery/marketing_receipt_lookup.ex" => 1,
    "samen_core/lib/samen/delivery/provider_conformance_case.ex" => 2,
    "samen_core/lib/samen/delivery/throttle.ex" => 2,
    "samen_core/lib/samen/derived_linkable.ex" => 1,
    "samen_core/lib/samen/erasure/completeness.ex" => 4,
    "samen_core/lib/samen/feature_flags.ex" => 1,
    "samen_core/lib/samen/files.ex" => 2,
    "samen_core/lib/samen/fleet/authz.ex" => 1,
    "samen_core/lib/samen/fleet/crypto.ex" => 1,
    "samen_core/lib/samen/fleet/public_status.ex" => 1,
    "samen_core/lib/samen/fleet/registry.ex" => 1,
    "samen_core/lib/samen/fleet/resolution.ex" => 6,
    "samen_core/lib/samen/gen/app.ex" => 1,
    "samen_core/lib/samen/identity/invite.ex" => 2,
    "samen_core/lib/samen/identity/reset.ex" => 1,
    "samen_core/lib/samen/jobs/queue_parity.ex" => 1,
    "samen_core/lib/samen/kms.ex" => 1,
    "samen_core/lib/samen/mailbox/match.ex" => 3,
    "samen_core/lib/samen/mailbox/sync.ex" => 1,
    "samen_core/lib/samen/marketing/consent.ex" => 1,
    "samen_core/lib/samen/marketing/consent_change.ex" => 5,
    "samen_core/lib/samen/metrics.ex" => 1,
    "samen_core/lib/samen/metrics/contention_handlers.ex" => 1,
    "samen_core/lib/samen/no_plaintext_pii.ex" => 1,
    "samen_core/lib/samen/no_plaintext_pii/context.ex" => 4,
    "samen_core/lib/samen/no_plaintext_pii/tiers/log_telemetry.ex" => 2,
    "samen_core/lib/samen/no_plaintext_pii/tiers/oban_jobs.ex" => 3,
    "samen_core/lib/samen/no_plaintext_pii/tiers/post_shred/replay.ex" => 2,
    "samen_core/lib/samen/no_plaintext_pii/tiers/vault_declarations.ex" => 1,
    "samen_core/lib/samen/non_pii.ex" => 1,
    "samen_core/lib/samen/notifications/engine.ex" => 1,
    "samen_core/lib/samen/notifications/status_change.ex" => 2,
    "samen_core/lib/samen/observability/job_spans.ex" => 4,
    "samen_core/lib/samen/observability/live_events.ex" => 2,
    "samen_core/lib/samen/observability/live_telemetry.ex" => 4,
    "samen_core/lib/samen/observability/param_filter.ex" => 2,
    "samen_core/lib/samen/operator_plane.ex" => 2,
    "samen_core/lib/samen/operator_plane/suspension.ex" => 3,
    "samen_core/lib/samen/pii/classification.ex" => 1,
    "samen_core/lib/samen/pii/info.ex" => 2,
    "samen_core/lib/samen/pii_classify.ex" => 1,
    "samen_core/lib/samen/pii_reads/registry.ex" => 3,
    "samen_core/lib/samen/replay.ex" => 2,
    "samen_core/lib/samen/replay/buffer.ex" => 7,
    "samen_core/lib/samen/replay/capture.ex" => 6,
    "samen_core/lib/samen/replay/decoder.ex" => 1,
    "samen_core/lib/samen/replay/player.ex" => 3,
    "samen_core/lib/samen/replay/resolver.ex" => 9,
    "samen_core/lib/samen/replay/row_guard.ex" => 1,
    "samen_core/lib/samen/replay/sanitizer.ex" => 2,
    "samen_core/lib/samen/retention.ex" => 1,
    "samen_core/lib/samen/reveal/grants.ex" => 2,
    "samen_core/lib/samen/scopes/identity/notify.ex" => 1,
    "samen_core/lib/samen/scopes/marketing/blueprint.ex" => 1,
    "samen_core/lib/samen/scopes/marketing/send_worker.ex" => 2,
    "samen_core/lib/samen/scopes/primitives/search_index_guard.ex" => 2,
    "samen_core/lib/samen/scopes/support/csat_survey.ex" => 2,
    "samen_core/lib/samen/search.ex" => 3,
    "samen_core/lib/samen/sequences.ex" => 1,
    "samen_core/lib/samen/sequences/receipt_lookup.ex" => 1,
    "samen_core/lib/samen/test_sandbox.ex" => 1,
    "samen_core/lib/samen/tracer.ex" => 3,
    "samen_core/lib/samen/transformers/materialize_pii.ex" => 1,
    "samen_core/lib/samen/vault.ex" => 1,
    "samen_core/lib/samen/verifiers/no_pii_columns.ex" => 1,
    "samen_core/lib/samen/versioning/select_for_version.ex" => 1,
    "samen_core/lib/samen/webhook/delivery_worker.ex" => 2,
    "samen_core/lib/samen/webhook/event.ex" => 1,
    "samen_core/lib/samen/webhook/ingest_worker.ex" => 2,
    "samen_core/lib/samen/webhook/payload.ex" => 4
  }

  @error_arm_baseline %{
    "samen_core/lib/samen/ai/agent/breaker.ex" => 1,
    "samen_core/lib/samen/ai/embeddings.ex" => 2,
    "samen_core/lib/samen/audit_event/partition_manager.ex" => 1,
    "samen_core/lib/samen/replay/resolver.ex" => 1,
    "samen_core/lib/samen/support/inbound/ingest.ex" => 1
  }

  def roots, do: @roots
  def baseline, do: @baseline
  def error_arm_baseline, do: @error_arm_baseline
  def reviewed, do: @reviewed

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

  @doc "Stale/inexact `reviewed/0` pins (`[]` when exact)."
  def reviewed_problems(files \\ files()), do: Swallow.reviewed_problems(repo_root(), files, @reviewed, :rescue)
end
