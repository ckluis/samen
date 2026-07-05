# S0.2 — Abbrev Storage Transformer

Spike proving Samen's **self-qualifying storage** idiom: you write idiomatic
`attribute :name`; a compile-time Spark transformer projects it to the physical
column `com_name` in the DB, migrations, and SQL — while app code, actions,
filters, and the public API keep addressing it by the logical name `:name`.

## What it does

```elixir
defmodule Crm.Contact do
  use Samen.Resource, abbrev: "com", data_layer: AshPostgres.DataLayer, ...

  attributes do
    attribute :name, :string      # stored as com_name
    attribute :org_id, :uuid       # stored as com_org_id
  end
end
```

`use Samen.Resource, abbrev: "com"` layers a Spark transformer
(`Samen.Transformers.AbbrevStorage`) that rewrites each attribute's Ash
`:source` to `"<abbrev>_<name>"`. AshPostgres uses `:source` as the physical
column name, so the generated migration, every emitted `WHERE`/`SELECT`, the
identity indexes, and the FK references all speak the prefixed name — with no
AshPostgres fork.

## Run

```bash
mix deps.get
mix test        # creates+migrates samen_spike_s02_test, runs green + red paths
```

The committed migration under `priv/repo/migrations/*_initial_spike.exs` is the
`mix ash.codegen` round-trip artifact; `mix ash.codegen --check` exits 0 (the
transformer output is idempotent under codegen).

## Acceptance (plan S0.2)

- generated migration contains `com_name` ✅ (`add(:com_name, :text)`)
- `Ash.create/read` work via `:name` ✅
- emitted SQL WHERE uses the prefixed column ✅
  (`WHERE (c0."com_name" = $1) AND (c0."com_org_id"::uuid = $2)`)
- **RED PATH:** a resource without `abbrev` fails compile with a clear
  diagnostic ✅ (verified fail-closed by an anti-tautology probe)

See `REPORT.md` for findings, including the R2 codegen-friction notes.
