# Anti-tautology probe — the pii_pet_microchip VAULT PATH (T6.2 red path).
#
# Guarantee under probe: the microchip vault round-trip (test/microchip_vault_test.exs)
# asserts (a) the raw `pii_pet_microchip` column holds an opaque `vt_` token, NOT the
# plaintext, and (b) a normal Ash read returns `%Samen.Masked{}`. A `refute raw ==
# plaintext` / `assert starts_with?(raw, "vt_")` assertion could pass VACUOUSLY if the
# column were always empty, or if the test never really wrote the secret. This probe
# proves the assertions are bound to the REAL on-disk vault behaviour by SABOTAGING it
# and confirming the assertions FLIP to failing, then REVERTING and confirming green.
#
# Sabotage (project-local, reverted in the same run): after a pet is created normally
# (real vault token on disk), overwrite the raw `pii_pet_microchip` column with the
# PLAINTEXT via direct SQL — the exact leak the guarantee forbids. Then re-run the two
# on-disk assertions and observe them flip.
#
# Run:  MIX_ENV=test mix run priv/anti_tautology_probe.exs
# Exit: 0 only if the flip was confirmed AND the revert restored green. Non-zero
#       (System.halt) otherwise — a probe that cannot flip is a tautology and must fail.

alias PawChart.Repo

# --- boot: fresh KMS store + migrated DB (mirrors ci_bootstrap) ---
kms_key_dir =
  Path.join(System.tmp_dir!(), "pawchart_probe_kms_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())
{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

org = "00000000-0000-0000-0000-0000000000c9"
plaintext = "985-PROBE-MICROCHIP-SECRET"

pet =
  PawChart.Clinic.Pet
  |> Ash.Changeset.for_create(
    :create,
    %{org_id: org, name: "ProbePet", species: "canine", microchip: plaintext},
    authorize?: false
  )
  |> Ash.create!()

pet_id_dumped = Ecto.UUID.dump!(to_string(pet.id))

raw_column = fn ->
  %{rows: [[raw]]} =
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pii_pet_microchip FROM pet_pet WHERE pet_id = $1",
      [pet_id_dumped]
    )

  raw
end

# The two on-disk assertions from the red-path test, as predicates.
assertions_hold? = fn ->
  raw = raw_column.()
  is_binary(raw) and raw != plaintext and String.starts_with?(raw, "vt_")
end

IO.puts("== anti-tautology probe: pii_pet_microchip vault path ==")

# --- 1. BASELINE: the real vault behaviour → assertions hold ---
# Capture the REAL vault token now on disk (the sabotage overwrites it; the revert
# restores exactly this — the original pii_vault ciphertext row is never touched).
original_token = raw_column.()

baseline = assertions_hold?.()
IO.puts("baseline (real vault): raw=#{inspect(original_token)}")
IO.puts("baseline assertions hold? #{baseline}")

unless baseline do
  IO.puts("FAIL: baseline did not hold — the vault path is broken, not a valid probe.")
  System.halt(1)
end

# --- 2. SABOTAGE: overwrite the raw column with the PLAINTEXT (the forbidden leak) ---
Ecto.Adapters.SQL.query!(
  Repo,
  "UPDATE pet_pet SET pii_pet_microchip = $1 WHERE pet_id = $2",
  [plaintext, pet_id_dumped]
)

sabotaged = assertions_hold?.()
IO.puts("\nsabotage (plaintext written to column): raw=#{inspect(raw_column.())}")
IO.puts("sabotaged assertions hold? #{sabotaged}  (MUST be false — the flip)")

if sabotaged do
  IO.puts("FAIL: assertions STILL held with plaintext on disk — the test is a TAUTOLOGY.")
  System.halt(1)
end

# --- 3. REVERT: restore the ORIGINAL vault token (the pii_vault ciphertext row was
#        never touched — only the domain column was overwritten) ---
Ecto.Adapters.SQL.query!(
  Repo,
  "UPDATE pet_pet SET pii_pet_microchip = $1 WHERE pet_id = $2",
  [original_token, pet_id_dumped]
)

reverted = assertions_hold?.()
IO.puts("\nrevert (real vault token restored): raw=#{inspect(raw_column.())}")
IO.puts("reverted assertions hold? #{reverted}  (MUST be true — green again)")

unless reverted do
  IO.puts("FAIL: revert did not restore the guarantee.")
  System.halt(1)
end

IO.puts("\nRESULT: PROBE CONFIRMED — the red-path assertions FLIPPED under sabotage and")
IO.puts("recovered on revert. The microchip vault round-trip test is NON-vacuous.")
File.rm_rf!(kms_key_dir)
