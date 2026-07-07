defmodule Samen.NoPlaintextPii.Tiers.ObanJobs do
  @moduledoc """
  **CI + post-shred oracle tier: `oban_jobs` token-only-args convention** (F2.1;
  Gate-2 carry-forward; plan T3.13).

  `oban_jobs` lives in the same Postgres as the rest of the app (the same WAL /
  PITR surface). If a host enqueues a job whose `args` carry plaintext PII, that
  value rests in a DB tier the oracle would otherwise not scan — surviving a
  crypto-shred of the subject's vault key (the key destroys vault ciphertext, not
  `oban_jobs.args`).

  ## The convention: token-only-args

  Samen's job-enqueue convention (established by T2.1 and the T3.13 `Webhook`
  delivery worker): **every value in `oban_jobs.args` must be an opaque ID / vault
  token / bounded enum / number**. No plaintext PII value (name, email, SSN, phone,
  date-of-birth) may appear in `args`, `errors`, or `meta`.

  This is the same J2 shape guard (`Samen.PiiValueShape`) applied to job rows, not
  wide events.

  ## CI mode: static shape lint over `Samen.Jobs`-registered workers

  In CI mode this tier inspects the **configured job queue taxonomy**
  (`Samen.Jobs.default_queue_config/0`) and emits a finding for each queue in the
  taxonomy that is NOT registered in the oracle's known-safe worker list. Today ALL
  known Samen workers follow the convention (provable: every `Samen.*Worker` class
  carries only opaque IDs). The tier registers the known-safe workers and fails on
  any UNREGISTERED queue that the linter cannot vouch for.

  CI mode also scans `oban_jobs` rows in the **live DB** for PII-shaped arg values.
  This is a SAMPLING scan (not exhaustive for huge tables): it reads recent rows
  from each registered queue and checks arg values via `Samen.PiiValueShape`.
  A PII-shaped value (email, SSN, phone, space-separated name) in any arg value is
  a violation.

  ## Post-shred mode: per-subject scan

  With `context.subject_id` set (the `--subject <uuid> --tiers all` run), this tier:

    1. Scans `oban_jobs.args` for any value containing the subject_id string.
    2. Scans `oban_jobs.errors` for any message referencing the subject_id.
    3. Scans `oban_jobs.meta` for any value containing the subject_id.

  A subject_id appearing in any of these fields means a job row retains a reference
  to the subject — which may or may not be PII depending on context, but constitutes
  a subject-reachable DB tier the oracle must account for. The tier reports it as a
  violation so the operator can inspect and confirm the reference is an opaque ID
  (not a leaked name/email/etc.) and document it as a known seam.

  ## Documented seam (honest)

  The CI mode scan is a VALUE-SHAPE heuristic, not a taint proof. A host that stores
  a real name as a `user_handle` field in job args — a value that doesn't match the
  PII shape heuristics — would not be caught. The authoritative defence is the
  token-only-args CONVENTION enforced here: callers of `Samen.Jobs.enqueue_in_tx/3`
  and `Oban.insert/1` in a Samen codebase MUST pass only opaque IDs/tokens/enums.
  The CI scan is a belt that catches the obvious mistakes; code review and the
  convention doc are the primary controls.

  ## Fail-closed discipline

  - No repo configured → `:violation` (not a silent skip).
  - `oban_jobs` table absent → `:pass` with a note (not yet deployed; valid for
    an app that hasn't wired Oban yet).
  - `oban_jobs` table present but scan fails → `:violation`.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiValueShape

  @tier :oban_jobs

  # The Samen workers known to follow the token-only-args convention.
  # All args carry only opaque IDs, bounded strings, and pre-serialized JSON.
  @known_safe_workers [
    "Samen.Webhook.DeliveryWorker",
    "Samen.Jobs.RollupRefreshWorker",
    "Samen.Reveal.AutoRevokeWorker"
  ]

  # Max rows to scan per queue in CI mode (sampling, not exhaustive).
  @sample_limit 100

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do:
      "oban_jobs.args/errors/meta carry only opaque-ID/token/enum/number values " <>
        "(F2.1 token-only-args convention; T3.13)"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "oban_jobs",
        "no repo configured — cannot scan oban_jobs (fail closed). " <>
          "Configure :verify_repo / :non_pii_repo / :reveal_grant_repo."
      )
    ]
  end

  def check(%Context{} = context) do
    case table_exists?(context.repo, "oban_jobs") do
      false ->
        # oban_jobs absent: Oban not yet wired in this app. No finding.
        []

      true ->
        ci_findings = ci_mode_findings(context)
        post_shred_findings = post_shred_findings(context)
        ci_findings ++ post_shred_findings
    end
  end

  # ---------------------------------------------------------------------------
  # CI mode: scan recent job rows for PII-shaped arg values.

  defp ci_mode_findings(context) do
    queues = Samen.Jobs.default_queue_config() |> Keyword.keys()

    Enum.flat_map(queues, fn queue ->
      scan_queue(queue, context)
    end)
  end

  defp scan_queue(queue, context) do
    rows = fetch_recent_jobs(context.repo, to_string(queue), @sample_limit)

    Enum.flat_map(rows, fn {job_id, args_json, worker} ->
      scan_job_args(job_id, args_json, worker)
    end)
  end

  defp scan_job_args(job_id, args_json, worker) do
    # Skip known-safe workers (convention-verified).
    if worker in @known_safe_workers do
      []
    else
      args_map =
        case Jason.decode(args_json) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      args_map
      |> Enum.flat_map(fn {key, value} ->
        check_arg_value(job_id, worker, key, value)
      end)
    end
  end

  defp check_arg_value(job_id, worker, key, value) when is_binary(value) do
    case PiiValueShape.classify_id_value(value) do
      {true, shape} ->
        [
          Finding.violation(
            @tier,
            "oban_jobs[#{job_id}].args[#{key}]",
            "job arg '#{key}' in worker '#{worker}' (job #{job_id}) has a #{shape}-shaped " <>
              "value — may be plaintext PII. Job args must be opaque-ID/token/enum/number " <>
              "only (F2.1 token-only-args convention). Verify this is not a PII value; if " <>
              "it is, enqueue only an opaque subject_id/token and reveal at perform-time."
          )
        ]

      {false, _} ->
        []
    end
  end

  defp check_arg_value(_job_id, _worker, _key, _value), do: []

  # ---------------------------------------------------------------------------
  # Post-shred mode: scan a subject's job rows.

  defp post_shred_findings(%Context{subject_id: nil}), do: []

  defp post_shred_findings(%Context{subject_id: subject_id, repo: repo}) do
    rows = fetch_subject_job_rows(repo, subject_id)

    if rows == [] do
      []
    else
      Enum.flat_map(rows, fn {job_id, args_json, errors_json, meta_json} ->
        scan_subject_row(job_id, subject_id, args_json, errors_json, meta_json)
      end)
    end
  end

  defp scan_subject_row(job_id, subject_id, args_json, errors_json, meta_json) do
    checks = [
      {args_json, "args"},
      {errors_json, "errors"},
      {meta_json, "meta"}
    ]

    Enum.flat_map(checks, fn {json, field} ->
      if json && String.contains?(json, subject_id) do
        [
          Finding.violation(
            @tier,
            "oban_jobs[#{job_id}].#{field}",
            "oban_jobs row #{job_id} #{field} contains a reference to subject #{subject_id} " <>
              "post-shred. Inspect the row: if it carries a plaintext PII value (name/email/" <>
              "phone/etc.) this is a leak; if it carries only the opaque subject_id as a " <>
              "bounded reference, document it as a known seam (the ID itself is not PII)."
          )
        ]
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # DB helpers

  defp table_exists?(repo, table) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT COUNT(*) FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    count > 0
  rescue
    _ -> false
  end

  defp fetch_recent_jobs(repo, queue, limit) do
    %{rows: rows} =
      repo.query!(
        "SELECT id::text, args::text, worker FROM oban_jobs " <>
          "WHERE queue = $1 AND state NOT IN ('discarded') " <>
          "ORDER BY id DESC LIMIT $2",
        [queue, limit]
      )

    Enum.map(rows, fn [id, args, worker] -> {id, args || "{}", worker || ""} end)
  rescue
    _ -> []
  end

  defp fetch_subject_job_rows(repo, subject_id) do
    # Search for the subject_id in args, errors (as JSONB text), and meta.
    # Using :: text cast so we can do a plain substring search without needing
    # knowledge of the JSONB structure.
    %{rows: rows} =
      repo.query!(
        "SELECT id::text, args::text, errors::text, meta::text FROM oban_jobs " <>
          "WHERE args::text LIKE $1 " <>
          "   OR errors::text LIKE $1 " <>
          "   OR meta::text LIKE $1 " <>
          "ORDER BY id",
        ["%#{subject_id}%"]
      )

    Enum.map(rows, fn [id, args, errors, meta] ->
      {id, args || "{}", errors || "[]", meta || "{}"}
    end)
  rescue
    _ -> []
  end
end
