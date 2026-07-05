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
    * `Samen.Transformers.AbbrevStorage` — rewrites every attribute `:source` to
      `<abbrev>_<name>`.

  ## Verifiers

    * `Samen.Verifiers.AbbrevRegistry` — enforces the committed abbrev registry
      (permanence, 3-letter-lowercase, collision-free, never-recycled). See
      `Samen.AbbrevRegistry`.
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
      Samen.Transformers.AbbrevStorage
    ],
    verifiers: [
      Samen.Verifiers.AbbrevRegistry
    ]
end
