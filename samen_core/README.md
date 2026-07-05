# samen_core

The Samen foundry kernel: **self-qualifying storage**, the **machine catalog**,
and the **PII vault** as one governed substrate for Ash/AshPostgres resources.

Elixir 1.20.2 / OTP 29, Ash 3.29.3, AshPostgres 2.10.0, Spark 2.7.2 (versions
pinned to `spikes/s00_smoke/VERSIONS.md`).

## What T1.1 ships (`Samen.Resource`)

Declare every resource with one macro:

```elixir
defmodule MyApp.Crm.Contact do
  use Samen.Resource,
    otp_app: :my_app,
    domain: MyApp.Crm,
    data_layer: AshPostgres.DataLayer,
    abbrev: "com"

  postgres do
    table "com_contact"
    repo MyApp.Repo
  end

  attributes do
    attribute :name, :string, public?: true   # stored as com_name
  end

  relationships do
    belongs_to :company, MyApp.Crm.Company     # FK stored as com_company_id -> cpy_company.cpy_id
  end
end
```

`use Samen.Resource` gives you, at compile time:

1. **Self-qualifying storage** — every physical column is prefixed with the
   resource's 3-letter abbrev (`com_name`, `com_org_id`, …) while app code keeps
   writing the logical name (`:name`). Implemented as a Spark transformer that
   rewrites each attribute's `:source`; AshPostgres uses `:source` verbatim, so
   migrations, SQL, identities, FK references, CDC, and logs all speak the
   prefixed name with no AshPostgres fork.
2. **The FK ordering fix (Gate-0 fix #2)** — the transformer runs *after*
   `BelongsToAttribute` so synthesized FK columns are prefixed too
   (`com_company_id`, not `company_id`) and target the composed table's prefixed
   PK. The `prefixes` verifier (T1.8a) is the fail-closed backstop.
3. **A first-class `samen do abbrev "com" end` section (S0.2 note F4)** —
   introspectable via `Samen.Info.abbrev/1`, and it survives fragment folding
   (not a module attribute). `abbrev: "com"` is sugar for the section.
4. **Injected universal columns** — `id`, `org_id`, `inserted_at`, `updated_at`
   on every resource (each prefixed). Additive/idempotent: declare any of them
   yourself to opt out.
5. **Fragment single-table composition** — `base: Core.Person` folds a
   `Spark.Dsl.Fragment` into ONE physical table (never Postgres `INHERITS`), with
   an **extension allow-list gate (Gate-0 fix #3)**: a fragment declaring a Samen
   extension the base macro does not provide fails compile (Spark would otherwise
   silently union it in). Uses `Code.ensure_compiled/1` to beat the compile race.
6. **The abbrev registry** — `priv/abbrev_registry.json` is the committed,
   permanent record of abbrev → owning resource. Abbrevs are **3-letter
   lowercase, collision-checked, and never recycled** (ticker-like). Claiming an
   unregistered abbrev, reusing an abbrev for a second resource, or changing a
   resource's abbrev all **fail compile**.

## The abbrev registry

To reserve an abbrev for a new resource, add a line to `priv/abbrev_registry.json`
and commit it:

```json
{
  "abbrevs": {
    "com": "MyApp.Crm.Contact"
  }
}
```

Abbrevs are permanent. Once data exists under `com_name`, that prefix cannot
change without rewriting history, so the registry refuses recycles and renames.

## Running the tests

Local Postgres on `localhost:5432`, role matching `$USER`, no password. The test
harness creates/migrates `samen_core_test` automatically.

```
mix test --warnings-as-errors
```

`test/test_helper.exs` owns the repo lifecycle (drop + create + migrate) so the
schema always matches the generated migrations in `priv/test_repo/migrations/`.

## Layout

- `lib/samen/resource.ex` — the base macro (abbrev, extensions, fragment gate,
  registry enforcement).
- `lib/samen/extension.ex` — the `samen` DSL section + transformer/verifier wiring.
- `lib/samen/transformers/core_attributes.ex` — injects id/org_id/timestamps.
- `lib/samen/transformers/abbrev_storage.ex` — the prefix transformer (FK ordering fix).
- `lib/samen/abbrev_registry.ex` + `priv/abbrev_registry.json` — the registry.
- `lib/samen/verifiers/abbrev_registry.ex` — compile-time registry verifier (defense in depth).
- `lib/samen/pii.ex`, `lib/samen/catalog.ex` — T1.1 baseline extensions (T1.2/T1.3+ flesh these out).
