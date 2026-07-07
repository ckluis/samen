defmodule Samen.Context.Dsl do
  @moduledoc """
  The Spark DSL **extension** carrying the `context do … end` section for
  `Samen.Context` (T3.10). Split out from `Samen.Context` because that module is
  the DSL *entry point* (`use Spark.Dsl`), and a Spark entry point takes its
  section macros from a separate extension module.

  Sections/entities:

    * `context` — the bounded-context map.
      * `alias_resource Kernel, as: Name` — re-identify a kernel noun.
      * `reshape Kernel do … end` — derived calculations over a kernel resource.
        * `calculate name, type, expr(...)` — one derived (computed) field.

  Transformer: `Samen.Context.Transformers.NoStorage` — the fail-closed guard that
  a reshape cannot touch storage.
  """

  # ---------------------------------------------------------------------------
  # `calculate` entity (nested under `reshape`)
  # ---------------------------------------------------------------------------
  @calculate %Spark.Dsl.Entity{
    name: :calculate,
    describe: """
    A derived (computed) field over the kernel resource's existing columns. Compiles
    to an Ash expression calculation loaded ad-hoc at query time — it NEVER declares
    a physical column or storage.
    """,
    target: Samen.Context.Calculation,
    args: [:name, :type, :expr],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The logical name of the derived field (e.g. :patient_responsibility)."
      ],
      type: [
        type: :any,
        required: true,
        doc:
          "The Ash type of the derived value. `:money` is sugar for `:decimal` " <>
            "(AshMoney is not a substrate dep); any Ash type module is accepted."
      ],
      expr: [
        type: :any,
        required: true,
        doc: "An `expr(...)` over the kernel resource's LOGICAL columns."
      ]
    ]
  }

  # ---------------------------------------------------------------------------
  # `reshape` entity — a block of calculations against ONE kernel resource
  # ---------------------------------------------------------------------------
  @reshape %Spark.Dsl.Entity{
    name: :reshape,
    describe: """
    Reshape a kernel resource's money/shape in the vertical's bounded context by
    adding derived calculations. Reads existing columns; adds NO storage.
    """,
    target: Samen.Context.Reshape,
    args: [:resource],
    entities: [calculations: [@calculate]],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc: "The kernel resource module being reshaped (e.g. Core.Invoice)."
      ]
    ]
  }

  # ---------------------------------------------------------------------------
  # `alias_resource` entity — re-identify a kernel noun under the vertical's name
  # ---------------------------------------------------------------------------
  @alias_resource %Spark.Dsl.Entity{
    name: :alias_resource,
    describe: """
    Re-identify a kernel resource under the vertical's ubiquitous language. The
    alias is a NAME, not a new resource — aliased actions run against the kernel
    resource, so its policies/vault/audit ride underneath unchanged.
    """,
    target: Samen.Context.Alias,
    args: [:resource],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc: "The kernel resource being re-identified (e.g. Core.Activity)."
      ],
      as: [
        type: :atom,
        required: true,
        doc: "The vertical's name for it (e.g. Lumen.Encounter)."
      ]
    ]
  }

  @context_section %Spark.Dsl.Section{
    name: :context,
    describe: "The bounded-context map: aliases and reshapes over the shared kernel.",
    # `Ash.Expr` so `reshape … calculate :x, :money, expr(total - covered_amount)`
    # resolves `expr/1` to an Ash expression struct (the same import Ash's own
    # `calculations` section uses).
    imports: [Ash.Expr],
    schema: [
      domain: [
        type: :atom,
        required: false,
        doc: "The vertical's Ash domain this bounded context belongs to."
      ]
    ],
    entities: [@alias_resource, @reshape]
  }

  use Spark.Dsl.Extension,
    sections: [@context_section],
    transformers: [Samen.Context.Transformers.NoStorage]
end
