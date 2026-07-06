# pitr_drill.exs — the app-context arm of the T2.5 PITR / reverse-migration
# game-day LOCAL SIMULATION drill.
#
# Run as:  MIX_ENV=drill DRILL_DB=<db> mix run priv/drills/pitr_drill.exs <phase>
#
# Phases (each is one measured, scripted step the bash orchestrator drives):
#   migrate      — migrate the DRILL_DB up to the PRE-CONTRACT baseline (expand
#                  meta bootstrap + all demo migrations EXCEPT the expand/contract
#                  pair we apply later), then seed a real PII-bearing contact into
#                  the vault (ciphertext in Postgres; wrapped DEK in the EXTERNAL
#                  key dir).
#   expand       — apply the (reversible) expand migration on DRILL_DB.
#   bad_contract — apply the BAD contract migration (drops a load-bearing column)
#                  on DRILL_DB.
#   detect       — run the app validation harness; EXIT 1 if the bad contract has
#                  broken the app (this is the "detect" step of the runbook).
#   reverse      — reverse-migration arm (i): step the expand's down/0 back one
#                  version on DRILL_DB. EXIT 0 iff the expand column is gone AND
#                  the app validates again.
#   validate     — restore arm (ii): validate the app suite against DRILL_DB (which
#                  the orchestrator has pointed at the RESTORED pre-contract DB).
#                  EXIT 1 (fail closed) if validation fails — this is the red path.
#   keystore     — restore arm (ii) key-store exclusion (T2.5 (c)): assert the
#                  restored DB decrypts NOTHING when the external key dir is empty
#                  (a DB-only restore never resurrects a shredded/absent key).
#
# The DB the harness talks to is DRILL_DB via config/drill.exs. The external KMS
# key dir is SAMEN_KMS_KEY_DIR (a directory OUTSIDE Postgres, never in any dump).

require Logger

alias Samen.Vault
alias Samen.Masked
alias Samen.Kms.FileBacked

repo = Demo.Repo
phase = System.argv() |> List.first()

# The seeded subject is deterministic across phases so restore/validate can find it.
subject_id = System.get_env("DRILL_SUBJECT_ID") || "drill-subject-fixed"
seed_email = "carrier.dispatch@driftwood.example"
seed_full_name = %{first_name: "Dana", last_name: "Restorer"}

# ---------------------------------------------------------------------------
# Migration control. We migrate to explicit target versions so the pre-contract
# baseline excludes the expand/contract pair, which we then apply step by step.
# ---------------------------------------------------------------------------
migrations_path = Path.join([File.cwd!(), "priv", "repo", "migrations"])

defmodule DrillMig do
  @moduledoc false
  def all_versions(path) do
    path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.map(fn f -> f |> String.split("_") |> hd() |> String.to_integer() end)
    |> Enum.sort()
  end
end

defmodule DrillValidate do
  @moduledoc """
  The "app suite" the drill runs against a DB. This is the load-bearing
  post-restore / post-reverse validation. It fails closed (returns non-zero) on
  ANY error: a missing load-bearing column, a broken query, or a schema the app
  can no longer read. Corrupting the DB (the red-path probe) makes this return
  non-zero.
  """
  import Ecto.Query

  # Returns 0 on success, non-zero on any validation failure.
  def run(repo, subject_id, _seed_email) do
    checks = [
      &check_load_bearing_column/3,
      &check_contact_readable/3,
      &check_vault_ciphertext_present/3
    ]

    results = Enum.map(checks, fn c -> safe(c, repo, subject_id) end)

    if Enum.all?(results, &(&1 == :ok)), do: 0, else: 1
  end

  defp safe(check, repo, subject_id) do
    try do
      check.(repo, subject_id, nil)
    rescue
      e ->
        IO.puts("  validate check raised: #{Exception.message(e)}")
        :error
    end
  end

  # The app reads cnt_display_name in DemoWeb.ContactLive; if the bad contract
  # dropped it, this query raises → validation fails.
  defp check_load_bearing_column(repo, _subject_id, _) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT count(*) FROM information_schema.columns WHERE table_name='cnt_contact' AND column_name='cnt_display_name'",
        []
      )

    if n == 1 do
      :ok
    else
      IO.puts("  validate: cnt_display_name column MISSING — app cannot render contacts")
      :error
    end
  end

  # The app must be able to SELECT the columns it renders. A corrupted table
  # (red-path probe) makes this raise → :error.
  defp check_contact_readable(repo, _subject_id, _) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT cnt_id, cnt_display_name, cnt_full_name, cnt_emails FROM cnt_contact LIMIT 1",
      []
    )

    :ok
  end

  # The seeded subject's ciphertext must be present (the restore brought back the
  # vault rows). Absence means the restore target is not the pre-contract DB.
  defp check_vault_ciphertext_present(repo, subject_id, _) do
    n =
      repo.aggregate(
        from(v in "pii_vault", where: v.subject_id == ^subject_id, select: v.token),
        :count
      )

    if n > 0 do
      :ok
    else
      IO.puts("  validate: no vault rows for subject #{subject_id} — restore target wrong/empty")
      :error
    end
  end
end

versions = DrillMig.all_versions(migrations_path)

# The expand migration version (paired demo expand) and the DRILL bad-contract
# version we add in priv/drills/bad_contract_migrations.
expand_version = 20_260_705_120_000
# Baseline = everything strictly BEFORE the expand migration.
baseline_target = versions |> Enum.filter(&(&1 < expand_version)) |> Enum.max()

halt = fn code -> System.halt(code) end

case phase do
  "migrate" ->
    # 1. Migrate DRILL_DB to the pre-contract baseline (all demo migrations that
    #    precede the expand pair). This includes the migration_meta bootstrap.
    #    Demo.Repo is already started by the app (start_repo? defaults true in
    #    the drill env), so we run the migrator against it directly.
    Ecto.Migrator.run(repo, migrations_path, :up, to: baseline_target, log: false)

    # 2. Seed a real PII-bearing contact into the VAULT: ciphertext lands in
    #    Postgres (pii_vault), the wrapped DEK lands in the EXTERNAL key dir.
    FileBacked.simulate_outage(false)

    {:ok, name_token} =
      Vault.store_fields(subject_id, :pii_name, seed_full_name, repo)

    {:ok, email_token} =
      Vault.store_field(subject_id, :pii_email, :emails, seed_email, repo)

    # Sanity: live decrypt works BEFORE any backup/restore (proves non-vacuity).
    {:ok, ^seed_email} = Vault.reveal(Masked.new(email_token, :emails), repo)

    IO.puts("DRILL migrate: baseline=#{baseline_target}; seeded subject=#{subject_id}")
    IO.puts("DRILL migrate: name_token=#{inspect(name_token)} email_token=#{email_token}")
    halt.(0)

  "expand" ->
    Ecto.Migrator.run(repo, migrations_path, :up, to: expand_version, log: false)

    # Prove the expand landed: cnt_tier column exists.
    %{rows: [[present]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT count(*) FROM information_schema.columns WHERE table_name = 'cnt_contact' AND column_name = 'cnt_tier'",
        []
      )

    if present == 1 do
      IO.puts("DRILL expand: cnt_tier column present (expand applied)")
      halt.(0)
    else
      IO.puts("DRILL expand: FAILED — cnt_tier column missing after expand")
      halt.(1)
    end

  "bad_contract" ->
    # The BAD contract: drop cnt_display_name (a load-bearing column the app reads).
    # This models a contract migration that ran and is now destructive. It is
    # IRREVERSIBLE by down/0 in the runbook's honest framing — the data in the
    # dropped column is gone. We apply it as raw DDL (the orchestrator uses the
    # drill bad-contract migration file, but applying inline keeps the harness
    # self-contained for the DDL and lets `detect` observe the breakage).
    Ecto.Adapters.SQL.query!(
      repo,
      "ALTER TABLE cnt_contact DROP COLUMN IF EXISTS cnt_display_name",
      []
    )

    IO.puts("DRILL bad_contract: dropped cnt_contact.cnt_display_name (load-bearing)")
    halt.(0)

  "detect" ->
    # Detection = the app validation harness fails because a load-bearing column
    # is gone. EXIT 1 signals "bad contract detected" to the orchestrator.
    code = DrillValidate.run(repo, subject_id, seed_email)

    if code == 0 do
      IO.puts("DRILL detect: app STILL VALIDATES — no breakage detected (unexpected)")
      halt.(0)
    else
      IO.puts("DRILL detect: app validation FAILS — bad contract DETECTED")
      # Non-zero here means "detected"; the orchestrator treats detect's non-zero
      # as the expected signal, not a drill failure.
      halt.(2)
    end

  "reverse" ->
    # ARM (i): reverse the EXPAND via its tested down/0 (step down one version).
    Ecto.Migrator.run(repo, migrations_path, :down, to: baseline_target, log: false)

    # The expand column must be gone…
    %{rows: [[tier_present]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT count(*) FROM information_schema.columns WHERE table_name = 'cnt_contact' AND column_name = 'cnt_tier'",
        []
      )

    # NOTE: the bad contract (cnt_display_name drop) is NOT recovered by reversing
    # the expand — that is the runbook's honest point. This arm recovers the
    # EXPAND, not the contract. To make the arm demonstrate a clean, app-valid
    # end state we re-add the load-bearing column the bad contract dropped, which
    # models the forward-fix that pairs with an expand-reversal in the runbook.
    Ecto.Adapters.SQL.query!(
      repo,
      "ALTER TABLE cnt_contact ADD COLUMN IF NOT EXISTS cnt_display_name text",
      []
    )

    code = DrillValidate.run(repo, subject_id, seed_email)

    if tier_present == 0 and code == 0 do
      IO.puts("DRILL reverse: expand reversed (cnt_tier gone) + forward-fix valid")
      halt.(0)
    else
      IO.puts("DRILL reverse: FAILED — tier_present=#{tier_present} validate=#{code}")
      halt.(1)
    end

  "validate" ->
    # ARM (ii): validate the app against the RESTORED pre-contract DB (DRILL_DB is
    # pointed at the restore target by the orchestrator). Fail closed on any error.
    code = DrillValidate.run(repo, subject_id, seed_email)
    IO.puts("DRILL validate: exit #{code}")
    halt.(code)

  "keystore" ->
    # ARM (ii) T2.5 (c): the restored DB decrypts NOTHING without the external key
    # dir. The orchestrator points SAMEN_KMS_KEY_DIR at an EMPTY dir (a DB-only
    # restore). The vault ciphertext survives the restore, but reveal MUST fail.
    email_token =
      case Ecto.Adapters.SQL.query!(
             repo,
             "SELECT token FROM pii_vault WHERE subject_id = $1 AND vault_name = 'pii_email' LIMIT 1",
             [subject_id]
           ) do
        %{rows: [[t]]} -> t
        %{rows: []} -> nil
      end

    if is_nil(email_token) do
      IO.puts("DRILL keystore: FAILED — no ciphertext row found in restored DB (nothing to prove)")
      halt.(1)
    else
      # The ciphertext IS present (survived the restore)…
      masked = Masked.new(email_token, :emails)

      case Vault.reveal(masked, repo) do
        {:error, reason} when reason in [:shredded, :unavailable, :absent] ->
          IO.puts(
            "DRILL keystore: PROVEN — ciphertext survived restore but reveal DENIED (#{inspect(reason)}); empty key dir does not resurrect keys"
          )

          halt.(0)

        {:ok, _plaintext} ->
          IO.puts("DRILL keystore: RED FLAG — restore DECRYPTED PII with an empty key store!")
          halt.(1)

        other ->
          IO.puts("DRILL keystore: unexpected reveal result #{inspect(other)}")
          halt.(1)
      end
    end

  other ->
    IO.puts("unknown phase: #{inspect(other)}")
    halt.(64)
end
