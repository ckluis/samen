# Anti-tautology probe — the `pii_pet_microchip` VAULT PATH (T6.2)

**Guarantee under probe:** the microchip vault round-trip
(`test/microchip_vault_test.exs`) asserts (a) the raw `pii_pet_microchip` column holds
an opaque `vt_` token — NOT the plaintext — and (b) a normal Ash read returns
`%Samen.Masked{}`. This is the doc's `pii_pat_microchip` idiom on the PawChart Pet
(abbrev `pet`), the second of the "two PII subjects".

**Why probe:** a `refute raw == plaintext` / `assert String.starts_with?(raw, "vt_")`
assertion could pass VACUOUSLY if the column were always empty, or if the create never
really wrote the secret. The probe proves the assertions are bound to the REAL on-disk
vault behaviour.

## Executable probe (project-local scratch keystore, reverted in the same run)

`priv/anti_tautology_probe.exs` (run: `MIX_ENV=test mix run priv/anti_tautology_probe.exs`)
does the flip → revert cycle against a real migrated DB:

1. **Baseline** — create a Pet with a real microchip; the domain column holds a `vt_`
   token; the two on-disk assertions HOLD.
2. **Sabotage** — overwrite the raw `pii_pet_microchip` column with the PLAINTEXT via
   direct SQL (the exact leak the guarantee forbids). The `pii_vault` ciphertext row is
   never touched — only the domain column.
3. **Re-check** — the two assertions FLIP to failing (`raw == plaintext`, not a `vt_`
   token).
4. **Revert** — restore the ORIGINAL vault token to the column; the assertions recover.

## Result — the flip (captured 2026-07-07)

```
== anti-tautology probe: pii_pet_microchip vault path ==
baseline (real vault): raw="vt_49e1401ebeba42ec99fb10f00d67fb4b"
baseline assertions hold? true

sabotage (plaintext written to column): raw="985-PROBE-MICROCHIP-SECRET"
sabotaged assertions hold? false  (MUST be false — the flip)

revert (real vault token restored): raw="vt_49e1401ebeba42ec99fb10f00d67fb4b"
reverted assertions hold? true  (MUST be true — green again)

RESULT: PROBE CONFIRMED — the red-path assertions FLIPPED under sabotage and
recovered on revert. The microchip vault round-trip test is NON-vacuous.
```

The assertions FLIPPED under sabotage (plaintext on disk → assertions fail) and
RECOVERED on revert (real token → assertions pass). The script `System.halt(1)`s if the
baseline does not hold, if the sabotage does NOT flip the assertions (a tautology), or
if the revert does not recover — so the probe itself fails closed. The microchip vault
round-trip red path is bound to the real on-disk vault behaviour, not vacuously passing.

The scratch keystore dir (`pawchart_probe_kms_*` under `$TMPDIR`) is removed at the end
of the run.
