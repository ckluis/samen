defmodule Samen.Scopes.Support.SlaBreachWorker do
  @moduledoc """
  Oban cron worker that detects and marks SLA breaches on support tickets (T3.6).

  ## Design

  Runs on a configurable cron schedule (default: `"* * * * *"` — every minute).
  Each tick:

  1. Queries the configured ticket table for rows where:
     - `sla_breach_at` IS NOT NULL
     - `sla_breach_at <= now()`
     - `breached = false`
  2. For each breached ticket: sets `breached = true` via SQL UPDATE.
  3. Emits a `support.ticket.breached` `aud_event` row per ticket via
     `Samen.Scopes.Support.Audit.ticket_breached/2`.

  ## E5 escalation client (ADR-039 §7.4 — T41 adoption seam)

  The scan, the `breached` flag flip, and the `aud_event` emission are UNCHANGED.
  The ONLY bespoke attention path — a direct `Samen.Notifications.Engine.emit/1`
  call — is REPLACED by `Samen.Automation.Escalate.open/2` (`kind: "sla_breach"`,
  `dedupe_key: ticket_id`, `deadline_at: breach_at`, `chain: nil` — the default
  single-step org chain, preserving the org-recipient notification this worker
  always sent). The escalation primitive now owns the attention/chain-walking;
  this worker owns ONLY the domain truth (the breach itself). Best-effort: an
  unwired/failing escalation call never aborts or reverts the breach flip
  (mirrors `Samen.Billing.Dunning`'s "never re-decides, never aborts the main
  path" posture for its own escalation calls).

  ## Why SQL rather than Ash actions

  The worker is mounted in `samen_core` but the ticket resource is a host-owned module
  resolved at runtime (the worker cannot `use` or compile-time-reference a host module).
  `Ash.Query.filter/2` is a compile-time macro that requires field names to be known at
  compile time — it cannot be used on a dynamically-resolved module. Using the raw repo
  + Ecto query directly is the correct seam: it is a maintenance worker, not a tenant-
  plane action, and the SQL it issues is dead simple (no policy evaluation needed —
  this is a system actor with explicit `authorize?: false` semantics baked in).

  The table name and column prefix are derived from the configured abbrev (or the
  default `stk`). This is the same convention `Samen.Migration.catalog_sync/1` uses.

  ## Configuration

  Mount by adding to your Oban crontab:

      {Oban.Plugins.Cron, crontab: [
        {"* * * * *", Samen.Scopes.Support.SlaBreachWorker}
      ]}

  Configure via app config:

      # Required: the repo to use for the breach scan
      config :samen_core, :support_sla_breach_repo, Demo.Repo

      # Optional: the abbrev prefix for the ticket table (default "stk")
      config :samen_core, :support_sla_ticket_abbrev, "stk"

  Or pass per-job args:

      Samen.Scopes.Support.SlaBreachWorker.new(%{
        "ticket_abbrev" => "stk"
      })

  ## Queue

  `:maintenance` queue (concurrency 1) — SLA breach detection is a low-frequency,
  sequential scan. One concurrent worker per node avoids duplicate-breach races
  (bounded by Oban's SKIP LOCKED + the idempotent `breached = false` WHERE clause).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @default_abbrev "stk"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    repo = resolve_repo(args)

    case repo do
      nil ->
        Logger.error(
          "[SlaBreachWorker] no repo configured — " <>
            "set config :samen_core, :support_sla_breach_repo, MyApp.Repo"
        )
        {:error, :no_repo_configured}

      repo ->
        abbrev = resolve_abbrev(args)
        scan_and_mark_breached(repo, abbrev)
    end
  end

  # Resolve the repo from args["repo"] → config → oban_config repo → nil.
  defp resolve_repo(%{"repo" => repo_str}) when is_binary(repo_str) do
    mod = String.to_existing_atom("Elixir.#{repo_str}")
    if Code.ensure_loaded?(mod), do: mod, else: nil
  rescue
    ArgumentError -> nil
  end

  defp resolve_repo(_args) do
    Application.get_env(:samen_core, :support_sla_breach_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :verify_repo) ||
      resolve_oban_repo()
  end

  defp resolve_oban_repo do
    case Application.get_env(:samen_core, Oban) do
      conf when is_list(conf) -> Keyword.get(conf, :repo)
      _ -> nil
    end
  end

  # Resolve the ticket table abbrev from args → config → default.
  defp resolve_abbrev(%{"ticket_abbrev" => abbrev}) when is_binary(abbrev), do: abbrev
  defp resolve_abbrev(_args) do
    Application.get_env(:samen_core, :support_sla_ticket_abbrev, @default_abbrev)
  end

  # Query the ticket table and mark breached rows.
  defp scan_and_mark_breached(repo, abbrev) do
    table = "#{abbrev}_ticket"
    id_col = "#{abbrev}_id"
    breach_col = "#{abbrev}_sla_breach_at"
    breached_col = "#{abbrev}_breached"
    org_col = "#{abbrev}_org_id"
    now = DateTime.utc_now()

    # Find tickets past their SLA deadline, not yet flagged. breach_col is
    # selected BOTH as text (the log-message form) and natively (untyped —
    # decodes as whatever the column's declared PG type is, so
    # Escalate.open/2's deadline_at gets a real DateTime/NaiveDateTime instead
    # of re-parsing the text form).
    query_sql = """
    SELECT #{id_col}::text, #{org_col}::text, #{breach_col}::text, #{breach_col}
    FROM #{table}
    WHERE #{breach_col} IS NOT NULL
      AND #{breach_col} <= $1
      AND #{breached_col} = false
    """

    case repo.query(query_sql, [now]) do
      {:ok, %{rows: rows}} ->
        Logger.debug("[SlaBreachWorker] found #{length(rows)} breached tickets in #{table}")

        Enum.each(rows, fn [id_bin, org_id_bin, breach_at_str, breach_at_native] ->
          mark_breached(repo, table, id_col, breached_col, id_bin, org_id_bin, breach_at_str, breach_at_native)
        end)

        :ok

      {:error, reason} ->
        Logger.error("[SlaBreachWorker] query failed on #{table}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_breached(repo, table, id_col, breached_col, id_bin, org_id_bin, breach_at_str, breach_at_native) do
    update_sql = """
    UPDATE #{table}
    SET #{breached_col} = true
    WHERE #{id_col} = $1::uuid
      AND #{breached_col} = false
    """

    # The `$1::uuid` cast makes Postgrex expect a 16-byte uuid binary — the
    # `::text`-selected id string from the scan would raise a DBConnection
    # EncodeError here (the flip NEVER landed against a real DB; the deeper half
    # of the H-9 "silent state flip" finding, caught by the A4 source tests).
    id_param =
      case Ecto.UUID.dump(id_bin) do
        {:ok, dumped} -> dumped
        :error -> id_bin
      end

    case repo.query(update_sql, [id_param]) do
      {:ok, %{num_rows: n}} when n > 0 ->
        # Emit the audit event. Build a minimal ticket map for the audit writer.
        ticket = %{id: id_bin, org_id: org_id_bin, sla_breach_at: breach_at_str}
        Samen.Scopes.Support.Audit.ticket_breached(repo, ticket, breach_at_str)

        # WS-A A4 event source (design §2.3; fixes H-9): the breach is no longer a
        # SILENT state flip. ADR-039 §7.4 (T41): attention now routes through the
        # E5 escalation primitive instead of a bespoke direct notify — Escalate.open
        # is idempotent-by-dedupe (a concurrent duplicate tick just advances the
        # SAME escalation, never opens a second one) and, with chain: nil, sends
        # the SAME org-recipient in_app notification this worker always sent (the
        # default single-step org chain), best-effort (never aborts the flip).
        escalate_breach(org_id_bin, id_bin, breach_at_native)

        Logger.info(
          "[SlaBreachWorker] marked ticket #{id_bin} as breached (breach_at=#{breach_at_str})"
        )

      {:ok, %{num_rows: 0}} ->
        # Already marked by a concurrent tick — idempotent, ignore.
        :ok

      {:error, reason} ->
        Logger.error("[SlaBreachWorker] UPDATE failed for #{id_bin}: #{inspect(reason)}")
    end
  end

  # Best-effort — an unwired/failing escalation call must NEVER surface as a
  # worker failure (the breach flip + audit above already committed).
  defp escalate_breach(org_id_bin, id_bin, breach_at_native) do
    case Samen.Automation.Escalate.open(%{
           org_id: org_id_bin,
           kind: "sla_breach",
           dedupe_key: id_bin,
           subject_ref: "samen:support.ticket:#{id_bin}",
           deadline_at: to_deadline(breach_at_native),
           chain: nil
         }) do
      {:ok, _escalation} ->
        :ok

      {:error, reason} ->
        Logger.debug("[SlaBreachWorker] escalation open skipped for #{id_bin}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[SlaBreachWorker] escalation open raised for #{id_bin}: #{Exception.message(e)}")
      :ok
  end

  # Normalize whatever the DB handed back for the untyped breach_col select
  # (a real DateTime for timestamptz, a NaiveDateTime for timestamp-without-tz,
  # or — defensively — a string) into a UTC DateTime for Escalate.open/2.
  defp to_deadline(%DateTime{} = dt), do: dt
  defp to_deadline(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp to_deadline(str) when is_binary(str) do
    normalized = String.replace(str, " ", "T", global: false)

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  defp to_deadline(_other), do: DateTime.utc_now()
end
