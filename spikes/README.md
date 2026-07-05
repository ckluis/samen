# Samen Spikes

Isolated proof-of-concept experiments for the highest-uncertainty Samen idioms.
Each spike is a self-contained Mix project that can be compiled and tested
independently, without touching the main application.

## Conventions

### One project per directory

Each spike lives in `spikes/sNN_<name>/` and is a standalone `mix new` project.
It has its own `mix.exs`, `deps/`, and `_build/`. No shared build artifacts.

### Own test database

Spikes that require Postgres create their own database:
`samen_spike_sNN_test` (e.g., `samen_spike_s02_test`).
Connection: `localhost:5432`, role = OS user (no password), same as the
main project. Each spike is responsible for creating/dropping its DB in
`test/test_helper.exs` or via a mix alias.

### Red-path tests are mandatory

Every spike MUST include at least one red-path test — a test that verifies
the system fails closed when given invalid input. A spike with no red-path
coverage is considered incomplete regardless of passing green tests.

Red-path tests follow this naming convention:

```elixir
test "red path: <what must fail> fails with <expected error>" do
  assert {:error, _} = SomeModule.operation(bad_input)
  # OR for compile-time failures:
  assert_raise CompileError, ~r/expected message/, fn ->
    Code.compile_string(bad_source)
  end
end
```

### VERSIONS.md

Each spike records its exact resolved dependency versions in `VERSIONS.md`
at the spike root. This is the permanent record of what compiled; do not
delete it.

### Report

Each spike produces a structured report (returned via `StructuredOutput`) with:
- `spike_id` — e.g., `S0.2`
- `status` — `green` | `green_with_caveats` | `blocked`
- `report_path` — absolute path to the spike report file
- `red_paths_failing_closed` — boolean: true only if ALL red-path tests pass AND
  they actually fail when the bad condition is present (must verify this)
- `findings` — list of notable findings, caveats, blocked reasons

### ci.sh integration

Each spike's tests are run by `ci.sh` at the repo root. When you add a spike,
add a stanza to `ci.sh` following the existing pattern.

## Spike index

| ID   | Directory            | Status | Purpose |
|------|----------------------|--------|---------|
| S0.0 | s00_smoke/           | green  | Smoke: verify Ash 3.x / ash_postgres / spark / oban resolve and compile |
| S0.2 | s02_transformer/     | green_with_caveats | Abbrev storage transformer (Spark DSL) — `source:` override drives `com_name` into migrations + SQL + identities + FKs; transformer must run AFTER `BelongsToAttribute` (R2 friction, documented) |
| S0.3 | s03_fragments/       | -      | Single-table composition via Spark.Dsl.Fragment |
| S0.4 | s04_catalog_tx/      | -      | Catalog rows written inside migration transaction |
| S0.5 | s05_vault/           | green  | PII vault / KMS / crypto-shred key hierarchy + %Masked{} |
| S0.7 | s07_pii_reads/       | green  | pii_reads AST verifier feasibility |
