defmodule Samen.Extension do
  @moduledoc """
  Spark DSL extension carrying the first-class `samen do … end` section and the
  abbrev storage transformer.

  ## The `samen` section (S0.2 note F4)

  Every Samen resource carries its 3-letter abbrev in a first-class, introspectable
  DSL section rather than a module attribute:

      samen do
        abbrev "com"
      end

  `use Samen.Resource, abbrev: "com"` is sugar that injects this section for you,
  but the section is the source of truth. Storing the abbrev in the DSL (not a
  `Module.get_attribute/2` value) matters for two reasons the spike flagged:

    * **Introspection** — `Samen.Info.abbrev(Resource)` reads it back through
      Spark's normal `Extension.get_opt/4` surface, so the catalog, verifiers, and
      LLM-grounding artifacts can all query it uniformly.
    * **Fragment folding** — a `Spark.Dsl.Fragment` has no module attributes of
      the composing resource; a section, by contrast, folds cleanly, so a fragment
      could in principle carry shared `samen` config. (Today abbrev is always set
      by the composing resource, never the fragment — a fragment has no abbrev of
      its own — but the section makes that a data decision, not a macro accident.)

  ## Transformers

  Ordering-sensitive; see each transformer's moduledoc:

    * `Samen.Transformers.CoreAttributes` — injects `id`, `org_id`,
      `inserted_at`, `updated_at` on every resource (runs before AbbrevStorage so
      they get prefixed).
    * `Samen.Transformers.MaterializeCustomFields` — when a resource declares a
      `:custom` jsonb bag (Tier-1), injects `Samen.CustomFields.Change` so every
      write to the bag is validated-at-write against the org's `tnt_field`
      definitions (type + constraint + PII-shape containment). Opt-in: no bag, no
      change.
    * `Samen.Transformers.AbbrevStorage` — rewrites every attribute `:source` to
      `<abbrev>_<name>`.
    * `Samen.Transformers.NoPanColumns` — the HARD compile-time abort for the B5
      no-PAN invariant (ADR-038 §3.5; T23): a resource declaring a PAN/CVC-shaped
      attribute does not compile, in any plane, in any host. Pairs with the
      `Samen.Verifiers.NoPanColumns` verifier below (same rule; the transformer's
      `{:error, _}` is what reliably aborts the build in this Ash/Spark version —
      see `Samen.Aggregate.NoPiiTransformer` for the precedent).

  ## Verifiers

    * `Samen.Verifiers.AbbrevRegistry` — enforces the committed abbrev registry
      (permanence, 3-letter-lowercase, collision-free, never-recycled). See
      `Samen.AbbrevRegistry`.
    * `Samen.Verifiers.TntBoundary` — enforces the Tier-2 one-way boundary (T3.9):
      a system resource declaring a relationship to `Samen.CustomObjects.Record`
      (`tnt_record`) fails compile. The tenant regime references OUT to system rows
      as validated opaque IDs, never the reverse.
    * `Samen.Verifiers.NoPanColumns` — enforces the B5 no-PAN invariant (ADR-038
      §3.5; T23): NO resource, in ANY plane, in ANY host, may declare an attribute
      shaped like a raw card number (PAN) or a card security code (CVC/CVV). Wired
      here (the base extension, not just the aggregate one) because card-on-file
      is a structural, plane-independent, forever invariant — samen never stores a
      PAN, full stop.
  """
  use Spark.Dsl.Extension,
    sections: [
      %Spark.Dsl.Section{
        name: :samen,
        describe: """
        Samen resource configuration. Carries the permanent, registry-checked
        storage abbrev that prefixes every physical column of this resource.
        """,
        schema: [
          abbrev: [
            type: :string,
            required: false,
            doc:
              "The resource's permanent 3-letter lowercase storage abbrev " <>
                "(e.g. \"com\"). Usually set via `use Samen.Resource, abbrev:`."
          ]
        ]
      }
    ],
    transformers: [
      Samen.Transformers.CoreAttributes,
      Samen.Transformers.MaterializeCustomFields,
      Samen.Transformers.AbbrevStorage,
      Samen.Transformers.NoPanColumns
    ],
    verifiers: [
      Samen.Verifiers.AbbrevRegistry,
      Samen.Verifiers.TntBoundary,
      Samen.Verifiers.NoPanColumns
    ]
end
