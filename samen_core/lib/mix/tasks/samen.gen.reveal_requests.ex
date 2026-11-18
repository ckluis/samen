defmodule Mix.Tasks.Samen.Gen.RevealRequests do
  @shortdoc "Write the retrofit migrations for the reveal-request org + decision-status columns (S6)."

  @moduledoc """
  `mix samen.gen.reveal_requests` — the retrofit for an app generated BEFORE a reveal request carried its own org and
  its own decision (`rvq_org_id`, and `rvq_status` kept up to date). A generated app is a copy and depends on
  `samen_core` by path: with the new `Samen.Reveal.RevealRequest` schema and the old table, every reveal read and write
  fails on the missing column. Run it inside the app (before or with the `samen_core` upgrade), then `mix ecto.migrate`.

  It writes TWO migrations (the paired expand pattern, `Samen.Migration.ExpandContract`):

    1. `<ts>_reveal_request_org_id.exs` — `ADD COLUMN IF NOT EXISTS rvq_org_id uuid` in a transaction under
       `expand_setup/0` (`lock_timeout`, so it fails loudly instead of queueing every reveal read behind a long
       transaction);
    2. `<ts+1>_reveal_request_backfill.exs` — outside the DDL transaction, in committed batches
       (`chunked_backfill/4`): `rvq_org_id` from the request's engine approval, `rvq_status` from what is on record
       (an approved / rejected / cancelled approval, a grant, a recorded denial), and the `(org, inserted_at, id)` index
       the queue's orphan scan reads, built `CONCURRENTLY`. A request whose state CANNOT be derived (no record, or
       records that disagree) stays `pending` and is counted in the migration's output: nothing is guessed.

  The SQL is LITERAL (table, columns, index names), like `mix samen.gen.indexes`: an applied migration never changes
  meaning. The committed `demo`, `driftwood` and test-repo migrations are this task's output for their prefixes.

  A freshly generated app does not need this: `m_reveal.eex` creates the table with the column.

  ## Usage

      mix samen.gen.reveal_requests [--approvals-prefix daa | --no-approvals] [--out path] [--timestamp 20261118100000]

  `--approvals-prefix` is the abbrev of the host's approvals table (`<prefix>_approval`); it defaults to the one of the
  resource configured as `config :samen_core, Samen.Approvals, approval_resource: …`. A host with no approvals engine
  takes `--no-approvals` (nothing to derive an org from; status comes from grants and the recorded denial only).
  `--timestamp` pins the first file's version (the second is one second later) and the module names.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv, strict: [out: :string, timestamp: :string, approvals_prefix: :string, no_approvals: :boolean])

    Mix.Task.run("app.config")
    Mix.Task.run("compile")

    prefix =
      cond do
        opts[:no_approvals] -> nil
        opts[:approvals_prefix] -> opts[:approvals_prefix]
        true -> configured_prefix()
      end

    repo = host_repo()
    out_dir = Keyword.get(opts, :out) || Ecto.Migrator.migrations_path(repo)
    timestamp = Keyword.get(opts, :timestamp) || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    next = bump(timestamp)

    {expand, backfill} = render(repo, prefix, timestamp)
    File.mkdir_p!(out_dir)
    first = Path.join(out_dir, "#{timestamp}_reveal_request_org_id.exs")
    second = Path.join(out_dir, "#{next}_reveal_request_backfill.exs")
    File.write!(first, expand)
    File.write!(second, backfill)
    Mix.shell().info("samen.gen.reveal_requests: wrote #{first} and #{second}")
    [first, second]
  end

  @doc """
  The two migration sources for `repo` and the approvals table abbrev `prefix` (`nil` = no approvals engine), pure.
  `opts[:suffix]` names the modules (default: the timestamp, so a re-run never collides with an earlier migration).
  """
  @spec render(module(), String.t() | nil, String.t(), keyword()) :: {String.t(), String.t()}
  def render(repo, prefix, timestamp, opts \\ []) do
    suffix = Keyword.get(opts, :suffix, timestamp)
    next = bump(timestamp)
    bindings = [repo: inspect(repo), p: prefix, suffix: suffix, ts: timestamp, next: next, approvals?: prefix != nil]

    {tidy(EEx.eval_string(expand_template(), bindings, trim: true)), tidy(EEx.eval_string(backfill_template(), bindings, trim: true))}
  end

  # the optional blocks leave a blank line behind: none right after a `do`, none right before an `end`, never two in a row
  defp tidy(source) do
    source
    |> String.replace(~r/ do\n\n/, " do\n")
    |> String.replace(~r/\n\n(\s*end\n)/, "\n\\1")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp bump(timestamp), do: Integer.to_string(String.to_integer(timestamp) + 1)

  defp host_repo do
    otp_app = Mix.Project.config()[:app]

    case Application.get_env(otp_app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> Mix.raise("mix samen.gen.reveal_requests: no :ecto_repos configured for #{inspect(otp_app)}")
    end
  end

  defp configured_prefix do
    case Application.get_env(:samen_core, Samen.Approvals, [])[:approval_resource] do
      nil ->
        Mix.raise("mix samen.gen.reveal_requests: no approvals engine configured; pass --approvals-prefix <abbrev> or --no-approvals")

      resource ->
        table = AshPostgres.DataLayer.Info.table(resource)

        case String.split(table || "", "_approval") do
          [prefix, ""] when prefix != "" -> prefix
          _ -> Mix.raise("mix samen.gen.reveal_requests: cannot read an abbrev from approvals table #{inspect(table)}; pass --approvals-prefix")
        end
    end
  end

  defp expand_template do
    ~S'''
    defmodule <%= repo %>.Migrations.RevealRequestOrgId<%= if suffix == "", do: "", else: suffix %> do
      @moduledoc """
      A reveal request carries the tenant org its engine approval is filed under (`rvq_org_id`), so a request whose
      `pii_reveal` approval failed to open can be found by org and re-opened (ADR-040 s4.7, S6). Expand, additive: a
      NULLABLE column (a row filed before this migration, or filed with no org, stays NULL; the code never guesses one).

      A bare `ADD COLUMN` takes ACCESS EXCLUSIVE, so it runs in a transaction under `expand_setup/0`: it waits at most
      `lock_timeout` for its lock and fails loudly instead of queueing every reveal read behind a long transaction. The
      backfill and the index are the paired migration `<%= next %>`, which runs outside the DDL transaction.
      Generated by `mix samen.gen.reveal_requests`; the table and column names are LITERAL.
      """
      use Samen.Migration, phase: :expand

      def change do
        expand_setup()

        execute(
          "ALTER TABLE rvq_reveal_request ADD COLUMN IF NOT EXISTS rvq_org_id uuid",
          "ALTER TABLE rvq_reveal_request DROP COLUMN IF EXISTS rvq_org_id"
        )
      end
    end
    '''
  end

  defp backfill_template do
    ~S'''
    defmodule <%= repo %>.Migrations.RevealRequestBackfill<%= if suffix == "", do: "", else: suffix %> do
      @moduledoc """
      The paired migration of `<%= ts %>` (`rvq_org_id`): the backfill and the index, outside the DDL transaction, in
      committed batches of 5,000 rows (`chunked_backfill/4`), so no long transaction holds a lock.

    <%= if approvals? do %>
        * `rvq_org_id` — from the request's engine approval (its `subject_ref` is `samen:reveal.request:<id>`, newest
          first). A request with no approval, or only a plane-global one, keeps NULL: `mix samen.verify.reveal_orgs`
          names it, and no org is guessed.
    <% end %>
        * `rvq_status` — a request that is still `pending` but was decided is marked with what the records say:
          `approved` (<%= if approvals?, do: "an approved approval or ", else: "" %>a grant for the request), `denied` (a rejected approval or the recorded
          "reveal request denied by approver" event), `cancelled` (a cancelled approval). A request whose records
          DISAGREE (say approved and denied) or that has none stays `pending`: it is counted in this migration's
          output and nothing is guessed.
        * the `(org, inserted_at, id)` index the queue's orphan scan reads, built `CONCURRENTLY` (an INVALID leftover
          of the same name is dropped first).
    <%= if approvals? do %>
      The lookups by approval `subject_ref` are served by a TEMPORARY partial index on the approvals table, built
      `CONCURRENTLY` for the backfill and dropped after it.
    <% end %>

      Every statement is idempotent (a re-run only does what is left). The table, columns and index names are LITERAL.
      Generated by `mix samen.gen.reveal_requests`.
      """
      use Samen.Migration, phase: :expand
      @disable_ddl_transaction true
      @disable_migration_lock true

      @index "rvq_reveal_request_org_inserted_at_id_idx"
    <%= if approvals? do %>
      @tmp_index "<%= p %>_approval_reveal_ref_tmp_idx"
      @request_ref "'samen:reveal.request:' || rvq_reveal_request.rvq_id::text"

      @approval_org """
      SELECT a.<%= p %>_org_id FROM <%= p %>_approval a
       WHERE a.<%= p %>_kind = 'pii_reveal' AND a.<%= p %>_org_id IS NOT NULL
         AND a.<%= p %>_subject_ref = 'samen:reveal.request:' || rvq_reveal_request.rvq_id::text
       ORDER BY a.<%= p %>_requested_at DESC NULLS LAST LIMIT 1
      """

      defp approval_in(state),
        do:
          "EXISTS (SELECT 1 FROM <%= p %>_approval a WHERE a.<%= p %>_kind = 'pii_reveal' AND a.<%= p %>_state = '#{state}' " <>
            "AND a.<%= p %>_subject_ref = #{@request_ref})"
    <% end %>

      @granted "EXISTS (SELECT 1 FROM rvg_reveal_grant g WHERE g.rvg_request_id = rvq_reveal_request.rvq_id)"
      @denial_recorded """
      EXISTS (SELECT 1 FROM rvl_reveal_audit l
               WHERE l.rvl_subject_id = rvq_reveal_request.rvq_subject_id
                 AND l.rvl_request_id = rvq_reveal_request.rvq_id
                 AND l.rvl_event = 'denied' AND l.rvl_detail = 'reveal request denied by approver')
      """

      defp approved, do: "(<%= if approvals? do %>#{approval_in("approved")} OR <% end %>#{@granted})"
      defp denied, do: "(<%= if approvals? do %>#{approval_in("rejected")} OR <% end %>#{@denial_recorded})"
      defp cancelled, do: "<%= if approvals? do %>#{approval_in("cancelled")}<% else %>false<% end %>"

      def up do
    <%= if approvals? do %>
        Samen.Migration.ExpandContract.drop_invalid_index("<%= p %>_approval", @tmp_index)

        execute(
          "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@tmp_index} ON <%= p %>_approval (<%= p %>_subject_ref) WHERE <%= p %>_kind = 'pii_reveal'"
        )

        # the statements above are queued: run them before the batches below read through the index
        flush()

        chunked_backfill(repo(), "rvq_reveal_request", "rvq_org_id = (#{@approval_org})",
          where: "rvq_org_id IS NULL AND EXISTS (#{@approval_org})"
        )
    <% end %>

        pending_only = "rvq_status = 'pending'"

        chunked_backfill(repo(), "rvq_reveal_request", "rvq_status = 'approved'",
          where: "#{pending_only} AND #{approved()} AND NOT #{denied()} AND NOT #{cancelled()}"
        )

        chunked_backfill(repo(), "rvq_reveal_request", "rvq_status = 'denied'",
          where: "#{pending_only} AND #{denied()} AND NOT #{approved()} AND NOT #{cancelled()}"
        )

        chunked_backfill(repo(), "rvq_reveal_request", "rvq_status = 'cancelled'",
          where: "#{pending_only} AND #{cancelled()} AND NOT #{approved()} AND NOT #{denied()}"
        )

        %{rows: [[undecided]]} =
          repo().query!(
            "SELECT count(*) FROM rvq_reveal_request WHERE #{pending_only} AND (#{approved()} OR #{denied()} OR #{cancelled()})",
            []
          )

        if undecided > 0 do
          IO.puts(
            "reveal request backfill: #{undecided} pending request(s) have records that disagree about how they were " <>
              "decided; left pending, not guessed (decide each by id: Samen.Reveal.Grants.approve/2 or deny/2)"
          )
        end

        concurrent_index("rvq_reveal_request", [:rvq_org_id, :rvq_inserted_at, :rvq_id], name: @index)
    <%= if approvals? do %>
        execute("DROP INDEX CONCURRENTLY IF EXISTS #{@tmp_index}")
    <% end %>
      end

      def down do
        execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
      end
    end
    '''
  end

end
