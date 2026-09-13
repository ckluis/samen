# pitr_drill.exs — the app-context arm of the T5.5 PITR / reverse-migration
# GAME-DAY #2 LOCAL SIMULATION drill against a PRODUCTION-SIZED Driftwood dataset.
#
# Run as:  MIX_ENV=drill DRILL_DB=<db> DRIFTWOOD_KMS_KEY_DIR=<dir> \
#            mix run --no-start priv/drills/pitr_drill.exs <phase>
#
# This is the Driftwood adaptation of demo/priv/drills/pitr_drill.exs (the T2.5
# machinery). It reuses the exact same drill grammar; the DIFFERENCES are:
#   * the dataset is PRODUCTION-SIZED (thousands of loads/settlements/drivers across
#     several tenants), committed so a real pg_dump captures it;
#   * the load-bearing validation is a SETTLEMENT-INTEGRITY check — it re-derives
#     `net_payable = max((linehaul+fuel+accessorial) − advances − factoring_fee −
#     claims, 0)` in SQL from the stored cents columns over the WHOLE dataset and
#     asserts it is consistent + non-empty (design §3 netting math);
#   * the BAD contract drops `stl_advances_cents` — a load-bearing settlement INPUT.
#     Dropping it silently zeroes advances, INFLATING net_payable (a freight broker
#     over-paying carriers). This is the freight-brokerage form of the "bad contract
#     that ran" incident.
#
# Phases (each is one measured, scripted step the bash orchestrator drives):
#   migrate      — migrate DRILL_DB to the current Driftwood schema (all CI
#                  migrations), then GENERATE the production-sized dataset and seed a
#                  real CDL-bearing driver into the vault (ciphertext in Postgres;
#                  wrapped DEK in the EXTERNAL key dir).
#   expand       — apply the reversible drill EXPAND (adds stl_settlement_note) whose
#                  tested down/0 recovery ARM (i) uses.
#   bad_contract — apply the BAD contract: DROP COLUMN stl_advances_cents (a
#                  load-bearing settlement input). Irreversible by down/0 (the data
#                  in the dropped column is gone) — covered by PITR, not down/0.
#   detect       — run the settlement-integrity harness; EXIT non-zero if the bad
#                  contract has broken settlement integrity (the "detect" step).
#   reverse      — recovery ARM (i): reverse the EXPAND via its tested down/0, then
#                  forward-fix (re-add the dropped column) and re-validate. EXIT 0 iff
#                  the expand column is gone AND settlement integrity holds again.
#   validate     — recovery ARM (ii): validate settlement integrity against DRILL_DB
#                  (the orchestrator points it at the RESTORED pre-contract DB). EXIT
#                  non-zero (fail closed) on any integrity failure — the RED PATH.
#   keystore     — ARM (ii) key-store exclusion (T5.5 (c)): assert the restored DB
#                  decrypts NOTHING (the driver CDL) when the external key dir is
#                  empty — a DB-only restore never resurrects a shredded/absent key.

require Logger

alias Driftwood.Repo
alias Samen.Vault
alias Samen.Masked
alias Samen.Kms.FileBacked

phase = System.argv() |> List.first()

# The seeded CDL-bearing driver is deterministic across phases so restore/validate/
# keystore can find it. (subject_id is a UUID string.)
subject_id = System.get_env("DRILL_SUBJECT_ID") || "5c5f4d3e-0000-4000-8000-000000000d11"
driver_cdl = "CDL-PITR-DRILL-707"

# The migrations path is the CI migration path (the current Driftwood schema); the
# drill expand lives in a SEPARATE path applied only when the `expand` phase runs.
migrations_path = Path.join([File.cwd!(), "priv", "repo", "migrations"])
expand_path = Path.join([File.cwd!(), "priv", "drills", "expand_migrations"])

# `20260905090000_expand_add_settlement_note.exs` (in migrations_path, the real CI
# migration path) and `20260707210000_drill_expand_settlement_note.exs` (in
# expand_path, the drill-only path) both add the same `stl_settlement_note` column —
# the real migration lands the identical expand PB3/UXD-04 engineered so
# `mix samen.verify.migrations` exercises a real down/0 for Driftwood outside this
# drill. Since `"migrate"` below applies ALL of migrations_path and `"expand"` then
# applies ALL of expand_path, applying both back-to-back collides (Postgres 42701
# duplicate_column). Stage a filtered COPY of migrations_path (symlinks; the real
# files are never touched) with that one migration excluded, so the drill's OWN
# expand migration is the one that actually adds/removes the column here — this
# affects only this drill's throwaway DB, never a real migrate/deploy path.
stage_drill_migrations = fn source_dir, excluded_basenames ->
  # D-10 fix: the old name (a per-BEAM-instance counter) was unique PER BEAM INSTANCE,
  # not per machine — it restarted on every run and collided against leftovers from
  # earlier runs (File.LinkError). Two create-and-own shapes, chosen by the caller:
  #   - the orchestrator (pitr_gameday_sim.sh) creates+owns the dir with `mktemp -d`
  #     (atomic, genuinely unique) and hands it in via DRIFTWOOD_DRILL_STAGING_DIR, so
  #     its own trap can remove it on an OS-level interrupt the BEAM cannot trap;
  #   - a direct `mix run` (no orchestrator) self-generates a name from the OS pid +
  #     nanosecond time and creates it with File.mkdir! (raises if it already exists —
  #     a pre-existing directory at the path is never silently reused).
  staged =
    case System.get_env("DRIFTWOOD_DRILL_STAGING_DIR") do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        path =
          Path.join(
            System.tmp_dir!(),
            "driftwood_drill_migrations_#{System.pid()}_#{System.system_time(:nanosecond)}"
          )

        File.mkdir!(path)
        path
    end

  source_dir
  |> Path.join("*.exs")
  |> Path.wildcard()
  |> Enum.reject(fn file -> Path.basename(file) in excluded_basenames end)
  |> Enum.each(fn file -> File.ln_s!(file, Path.join(staged, Path.basename(file))) end)

  staged
end

# ---------------------------------------------------------------------------
# Boot the repo ourselves (--no-start): plain connection pool (committed writes),
# pinned KMS keystore. Mirrors crypto_shred_gameday.exs's boot.
# ---------------------------------------------------------------------------
kms_dir = System.get_env("DRIFTWOOD_KMS_KEY_DIR") || raise "set DRIFTWOOD_KMS_KEY_DIR"
Application.put_env(:samen_core, :kms_key_dir, kms_dir)

{:ok, _} = Repo.start_link()

FileBacked.simulate_outage(false)

halt = fn code -> System.halt(code) end

# The SETTLEMENT-INTEGRITY harness — the load-bearing post-restore / post-reverse
# validation — lives in lib (Driftwood.PitrGameday.SettlementIntegrity) so the drill
# AND the red-path test (test/pitr_gameday2_test.exs) exercise IDENTICAL logic. It
# re-derives the design §3 netting math in SQL from the stored cents columns and
# returns {:ok, %{settlements: n}} | {:error, reason} (fail closed on the first
# broken check). Dropping stl_advances_cents (the bad contract OR the red-path
# corruption) makes it return {:error, ...}.
alias Driftwood.PitrGameday.SettlementIntegrity

# ===========================================================================
# The production-sized dataset generator. Several tenants, thousands of loads and
# settlements and hundreds of drivers. Written with raw multi-row INSERTs (fast,
# committed, and it is the DATA the pg_dump must faithfully round-trip). One driver
# is ALSO vault-seeded with a real CDL (ciphertext in Postgres, DEK in the external
# key dir) so the key-store-exclusion arm has a real subject.
# ===========================================================================
defmodule DrillDataset do
  @moduledoc false

  # Tunable via env so CI can run a smaller-but-still-multi-thousand dataset fast.
  def tenants, do: String.to_integer(System.get_env("DRILL_TENANTS") || "4")
  def carriers_per_tenant, do: String.to_integer(System.get_env("DRILL_CARRIERS") || "40")
  def loads_per_tenant, do: String.to_integer(System.get_env("DRILL_LOADS") || "600")
  # settlements_per_tenant == loads_per_tenant (one settlement per delivered load).

  def generate(repo) do
    :rand.seed(:exsss, {5, 5, 5})

    org_ids = for _ <- 1..tenants(), do: uuid()

    totals =
      Enum.reduce(org_ids, %{carriers: 0, loads: 0, settlements: 0}, fn org_id, acc ->
        carrier_ids = insert_carriers(repo, org_id, carriers_per_tenant())
        load_ids = insert_loads(repo, org_id, loads_per_tenant())
        n_settle = insert_settlements(repo, org_id, carrier_ids, load_ids)

        %{
          carriers: acc.carriers + length(carrier_ids),
          loads: acc.loads + length(load_ids),
          settlements: acc.settlements + n_settle
        }
      end)

    Map.put(totals, :tenants, length(org_ids))
  end

  defp insert_carriers(repo, org_id, n) do
    ids = for _ <- 1..n, do: uuid()
    now = ts()

    values =
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, i} ->
        "('#{id}','Carrier #{String.slice(id, 0, 6)}-#{i}','#{org_id}','#{now}','#{now}')"
      end)
      |> Enum.join(",")

    Ecto.Adapters.SQL.query!(
      repo,
      "INSERT INTO fcm_company (fcm_id, fcm_name, fcm_org_id, fcm_inserted_at, fcm_updated_at) VALUES #{values}",
      []
    )

    ids
  end

  defp insert_loads(repo, org_id, n) do
    ids = for _ <- 1..n, do: uuid()
    now = ts()

    # fop_opportunity: mounted CRM Opportunity (re-identified as Load). Insert the
    # minimum non-null columns; the settlement FK references fop_id.
    values =
      ids
      |> Enum.with_index()
      |> Enum.chunk_every(500)

    Enum.each(values, fn chunk ->
      vals =
        chunk
        |> Enum.map(fn {id, i} ->
          "('#{id}','Load #{String.slice(id, 0, 6)}-#{i}','#{org_id}','#{now}','#{now}')"
        end)
        |> Enum.join(",")

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO fop_opportunity (fop_id, fop_name, fop_org_id, fop_inserted_at, fop_updated_at) VALUES #{vals}",
        []
      )
    end)

    ids
  end

  # One settlement per load, with realistic random money inputs (integer cents).
  # This is the data the netting integrity check re-derives.
  defp insert_settlements(repo, org_id, carrier_ids, load_ids) do
    now = ts()

    load_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(0, fn chunk, acc ->
      vals =
        chunk
        |> Enum.map(fn load_id ->
          carrier_id = Enum.random(carrier_ids)
          linehaul = :rand.uniform(400_000) + 50_000
          fuel = :rand.uniform(30_000)
          accessorial = :rand.uniform(15_000)
          # advances sometimes exceed linehaul (the carryover edge, design §3.5 ex.3)
          advances = :rand.uniform(round(linehaul * 1.2))
          claims = :rand.uniform(8_000)
          bps = Enum.random([0, 150, 200, 250, 300, 350])
          id = uuid()

          "('#{id}','#{org_id}','#{load_id}','#{carrier_id}'," <>
            "#{linehaul},#{advances},#{fuel},#{accessorial},#{claims},#{bps},'USD','approved','#{now}','#{now}')"
        end)
        |> Enum.join(",")

      Ecto.Adapters.SQL.query!(
        repo,
        """
        INSERT INTO stl_settlement
          (stl_id, stl_org_id, stl_load_id, stl_carrier_id,
           stl_linehaul_cents, stl_advances_cents, stl_fuel_surcharge_cents,
           stl_accessorial_cents, stl_claim_deduction_cents, stl_factoring_rate_bps,
           stl_currency, stl_status, stl_inserted_at, stl_updated_at)
        VALUES #{vals}
        """,
        []
      )

      acc + length(chunk)
    end)
  end

  defp uuid, do: Ecto.UUID.generate()
  defp ts, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
end

# ===========================================================================
# Phases
# ===========================================================================
case phase do
  "migrate" ->
    # 1. Migrate DRILL_DB to the CURRENT Driftwood schema (all CI migrations),
    #    EXCLUDING the real-path settlement-note expand migration — the drill's OWN
    #    expand migration (applied by the "expand" phase below) adds the identical
    #    column under its own change_key; see the `stage_drill_migrations` comment
    #    above for why.
    drill_migrations_path =
      stage_drill_migrations.(migrations_path, [
        "20260905090000_expand_add_settlement_note.exs"
      ])

    # D-10: the staging dir is removed on every exit path the BEAM itself can reach out
    # of this branch — success (below, before halt) and any raised failure (rescue,
    # which cleans up then re-raises the SAME exception so the failure signal is
    # unchanged). An OS-level interrupt is NOT reachable here at all (no :sigint clause
    # in System.trap_signal/3, and a SIGTERM kill gives no chance to run this rescue
    # either) — that path is the bash orchestrator's trap in pitr_gameday_sim.sh,
    # matching ci.sh's run_gen_probe wrapper (T107, repo CLAUDE.md).
    try do
      Ecto.Migrator.run(Repo, drill_migrations_path, :up, all: true, log: false)
      :ok = Driftwood.NonPiiSetup.register_all()

      # 2. Generate the PRODUCTION-SIZED dataset (thousands of loads/settlements across
      #    several tenants). Committed — the pg_dump must capture it.
      totals = DrillDataset.generate(Repo)

      # 3. Seed a real CDL-bearing DRIVER into the vault: the scalar pii_drv_cdl_number
      #    ciphertext lands in Postgres (pii_vault), the wrapped DEK lands in the
      #    EXTERNAL key dir. This is the subject the key-store-exclusion arm uses.
      {:ok, cdl_token} =
        Vault.store_field(subject_id, :pii_cdl, :cdl_number, driver_cdl, Repo)

      # Sanity: live decrypt works BEFORE any backup/restore (proves non-vacuity).
      {:ok, ^driver_cdl} = Vault.reveal(Masked.new(cdl_token, :cdl_number), Repo)

      IO.puts(
        "DRILL migrate: dataset generated — #{totals.tenants} tenants, " <>
          "#{totals.carriers} carriers, #{totals.loads} loads, #{totals.settlements} settlements"
      )

      IO.puts("DRILL migrate: seeded CDL-bearing driver subject=#{subject_id} cdl_token=#{cdl_token}")
    rescue
      e ->
        File.rm_rf!(drill_migrations_path)
        reraise e, __STACKTRACE__
    end

    File.rm_rf!(drill_migrations_path)
    halt.(0)

  "expand" ->
    # Apply the reversible drill EXPAND (adds stl_settlement_note). This has a tested
    # down/0 that recovery ARM (i) drives.
    Ecto.Migrator.run(Repo, expand_path, :up, all: true, log: false)

    %{rows: [[present]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM information_schema.columns WHERE table_name='stl_settlement' AND column_name='stl_settlement_note'",
        []
      )

    if present == 1 do
      IO.puts("DRILL expand: stl_settlement_note column present (expand applied)")
      halt.(0)
    else
      IO.puts("DRILL expand: FAILED — stl_settlement_note column missing after expand")
      halt.(1)
    end

  "bad_contract" ->
    # The BAD contract: drop stl_advances_cents (a load-bearing settlement INPUT).
    # This models a contract migration that ran and is now destructive: with advances
    # gone, the netting derivation silently treats advances as 0 and OVER-PAYS every
    # carrier. IRREVERSIBLE by down/0 (the advance data is gone) — covered by PITR.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE stl_settlement DROP COLUMN IF EXISTS stl_advances_cents",
      []
    )

    IO.puts("DRILL bad_contract: dropped stl_settlement.stl_advances_cents (load-bearing input)")
    halt.(0)

  "detect" ->
    # Detection = the settlement-integrity harness fails because a load-bearing input
    # is gone. EXIT non-zero signals "bad contract detected" to the orchestrator.
    case SettlementIntegrity.run(Repo) do
      {:ok, summary} ->
        IO.puts(
          "DRILL detect: settlement integrity STILL HOLDS (#{summary.settlements} settlements) — no breakage detected (unexpected)"
        )

        halt.(0)

      {:error, reason} ->
        IO.puts("DRILL detect: settlement integrity FAILS — bad contract DETECTED: #{reason}")
        # Non-zero here means "detected"; the orchestrator treats detect's non-zero as
        # the expected signal, not a drill failure.
        halt.(2)
    end

  "reverse" ->
    # ARM (i): reverse the EXPAND via its tested down/0.
    Ecto.Migrator.run(Repo, expand_path, :down, all: true, log: false)

    %{rows: [[note_present]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM information_schema.columns WHERE table_name='stl_settlement' AND column_name='stl_settlement_note'",
        []
      )

    # The bad contract (advances drop) is NOT recovered by reversing the expand — that
    # is the runbook's honest point. This arm recovers the EXPAND, not the contract.
    # To reach a clean, app-valid end state we FORWARD-FIX: re-add the dropped column
    # (in a real incident, its values are re-derived from the rate-confirmation source
    # or accepted as a known write-loss; here we re-add and backfill 0 to model the
    # forward-fix that pairs with expand-reversal — the honest note is that the ORIGINAL
    # advance values are only recoverable via ARM (ii) restore).
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE stl_settlement ADD COLUMN IF NOT EXISTS stl_advances_cents integer NOT NULL DEFAULT 0",
      []
    )

    result = SettlementIntegrity.run(Repo)

    case {note_present, result} do
      {0, {:ok, summary}} ->
        IO.puts(
          "DRILL reverse: expand reversed (stl_settlement_note gone) + forward-fix valid (#{summary.settlements} settlements integrity-OK)"
        )

        halt.(0)

      {_, other} ->
        IO.puts("DRILL reverse: FAILED — note_present=#{note_present} integrity=#{inspect(other)}")
        halt.(1)
    end

  "validate" ->
    # ARM (ii): validate settlement integrity against the RESTORED pre-contract DB
    # (DRILL_DB is pointed at the restore target by the orchestrator). Fail closed on
    # any integrity failure — this is the RED PATH.
    case SettlementIntegrity.run(Repo) do
      {:ok, summary} ->
        IO.puts("DRILL validate: settlement integrity HOLDS (#{summary.settlements} settlements) — exit 0")
        halt.(0)

      {:error, reason} ->
        IO.puts("DRILL validate: settlement integrity FAILED (fail closed): #{reason}")
        halt.(1)
    end

  "keystore" ->
    # ARM (ii) T5.5 (c): the restored DB decrypts NOTHING (the driver CDL) without the
    # external key dir. The orchestrator points DRIFTWOOD_KMS_KEY_DIR at an EMPTY dir (a
    # DB-only restore). The CDL ciphertext survives the restore, but reveal MUST fail.
    cdl_token =
      case Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT token FROM pii_vault WHERE subject_id = $1 AND vault_name = 'pii_cdl' LIMIT 1",
             [subject_id]
           ) do
        %{rows: [[t]]} -> t
        %{rows: []} -> nil
      end

    if is_nil(cdl_token) do
      IO.puts("DRILL keystore: FAILED — no CDL ciphertext row in restored DB (nothing to prove)")
      halt.(1)
    else
      # The ciphertext IS present (survived the restore)…
      masked = Masked.new(cdl_token, :cdl_number)

      case Vault.reveal(masked, Repo) do
        {:error, reason} when reason in [:shredded, :unavailable, :absent] ->
          IO.puts(
            "DRILL keystore: PROVEN — CDL ciphertext survived restore but reveal DENIED (#{inspect(reason)}); empty key dir does not resurrect keys"
          )

          halt.(0)

        {:ok, _plaintext} ->
          IO.puts("DRILL keystore: RED FLAG — restore DECRYPTED the driver CDL with an empty key store!")
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
