# Gate-6 Fix — A6: webhook storage-name guard keys on the DECLARED abbrev (P1)

- **Date:** 2026-07-07
- **Finding:** Gate-6 report §Caveats.4 / extraction-retro A6 (P1 backlog).
- **Status:** **FIXED.** Green-before → green-after, root `bash ci.sh` exit **0** both times.

---

## The bug

`Samen.Webhook.Payload`'s secondary storage-name guard used a blanket regex
`~r/^[a-z]{3}_/` to strip physical storage column names from an already-allowlisted
webhook payload. It **false-positived** on legitimate freight CATALOG names that
merely start with a 3-letter token + underscore — `cdl_number`, `cdl_state`,
`cdl_expiry`, `eld_provider` — and **silently dropped** them from the webhook body.
Fail-safe (absent by omission, never a leak) but wrong: those fields belong in the
payload. The JSON:API surface rendered them correctly because it does not use this
heuristic.

## The fix

`samen_core/lib/samen/webhook/payload.ex`:

- Read the resource's **declared abbrev** via `Samen.Info.abbrev/1` (the DSL source of
  truth; `nil` for non-`Samen.Resource` modules, rescued to `nil`).
- `storage_name?/2` now treats a name as a storage name **only if** it starts with
  THIS resource's own `<abbrev>_` prefix, its `pii_<abbrev>_` vault prefix, or the
  generic `pii_` storage-artifact prefix (kept as belt-and-suspenders). No more blanket
  3-letter regex.
- A catalog name is never prefixed with its own resource's abbrev (the storage
  transformer prefixes *physical* columns; the catalog name maps from the un-prefixed
  one), so `cdl_number` on the `drv` Driver survives while a genuine `drv_*` leak is
  still stripped.
- Moduledoc updated to describe the abbrev-keyed guard.

**Composition with the Phase-3 opt-in allowlist:** unchanged and confirmed. `show_fields`
remains the PRIMARY gate — a field must be explicitly allowlisted (catalog name) to even
reach this secondary guard. When the abbrev is unknown (`nil`), only the `pii_` guard
applies (fail-safe: we never invent a prefix that would over-drop a catalog name).

## Tests

- **demo** `test/webhook_payload_allowlist_test.exs` — 4 new A6 red paths (fixture
  `Demo.WebhookAllowlist.Widget`, abbrev `waw`, extended with `cdl_number` + `waw_leaked_col`):
  1. a catalog name starting with a 3-letter token+underscore (`cdl_number`) **SURVIVES**.
  2. a name starting with the resource's own abbrev (`waw_leaked_col`) is **STILL stripped**
     even when (mistakenly) allowlisted.
  3. the opt-in allowlist **still governs** — a non-allowlisted field is still absent.
  4. **masked PII still serializes as `••••`** (composes with A6; no plaintext, no `vt_` token).
- **driftwood** `test/api_external_surface_test.exs` — updated the `driver.updated` webhook
  test: `cdl_number` now asserts `••••` (masked, surviving), and `cdl_state`/`cdl_expiry`/
  `eld_provider` now assert their catalog values survive (previously-dropped fields).
- samen_core webhook tests unchanged and green (samen_core carries no AshJsonApi, so its
  allowlist is empty and the guard is not exercised there — the abbrev-keyed paths run in
  the demo host where a real `show_fields` allowlist exists).

## Red paths

| # | Red path | Result |
|---|----------|--------|
| 1 | allowlisted Driver includes `cdl_number`/`cdl_state`/`eld_provider` under catalog names | **survive** (were dropped before) |
| 2 | an actual storage-prefixed name (`waw_leaked_col` / `drv_*`) allowlisted by mistake | **still stripped** |
| 3 | a non-allowlisted field (`internal_label`) | **still absent** (opt-in allowlist governs) |
| 4 | masked PII (`%Masked{}`) | **still `••••`** (no plaintext, no `vt_` token) |

## Anti-tautology probe

Sabotaged the abbrev-keyed check in a project-local scratch (`.a6_scratch/`, removed):
reverted `storage_name?/2` to the OLD blanket `~r/^[a-z]{3}_/` regex, ran demo red path (1)
→ it **FLIPPED to failing** (`cdl_number` dropped again — `assert data["cdl_number"] ==
"CDL-12345"` failed). Restored `payload.ex` **byte-identical** (md5
`a401563f7238bb8a9cb7af8f7c8c3a28` before and after), removed the scratch. The red path
exercises the real fix, not a tautology.

## Green (per-app, root `bash ci.sh` exit 0 both before and after)

- **samen_core:** 842 passed (9 properties, 833 tests), `--warnings-as-errors`.
- **demo:** 403 passed (17 properties, 386 tests) **[+4 A6 red paths, was 399]** + 52
  adversarial + demo CI gate.
- **driftwood:** 58 passed (1 property) + 4 adversarial + full 19-step CI gate.
- **pawchart:** 19 passed + full 17-step CI gate (microchip anti-tautology probe).
- **spikes:** s00/s02/s03/s04/s05/s07 all green.
- **ROOT CI: ALL PASSED, exit 0.**

## Caveat

None material. The fix is scoped to one core module + tests; the abbrev is read from the
existing `Samen.Info.abbrev/1` surface (no new introspection). For a resource that does not
`use Samen.Resource` (abbrev `nil`), the guard degrades to the `pii_`-only check — fail-safe
(never over-drops a catalog name; the opt-in allowlist is still the primary gate).
