defmodule Samen.Context do
  @moduledoc """
  The **bounded-context DSL** (plan T3.10; vision doc §core `Lumen.Context` block).

  The top rung of the malleability ladder (vision doc §"A malleability ladder"):
  *not merely "more malleability" — a context boundary where a vertical writes its
  own ubiquitous language over the shared infrastructure.* Two of the three worked
  verticals (Driftwood, Lumen) are **bounded-context translations, not additive
  extensions**: they re-identify the kernel nouns (`Company → Carrier`,
  `Activity → Encounter`) and reshape money (settlement-netting; a
  `patient_responsibility + payer_claim` split). `Samen.Context` is the thin
  **anti-corruption layer** that makes that honest:

      defmodule Lumen.Context do
        use Samen.Context

        context do
          domain Lumen.Clinical

          # kernel Activity re-identified as the vertical's Encounter (aliased action)
          alias_resource Core.Activity, as: Lumen.Encounter

          # kernel invoice money reshaped: one charge → patient_responsibility + payer_claim
          reshape Core.Invoice do
            calculate :patient_responsibility, :money, expr(total - covered_amount)
            calculate :payer_claim, :money, expr(covered_amount)
          end
        end
      end

  (The vision-doc block writes `use Samen.Context, domain: X` with the
  `alias_resource`/`reshape` calls at the top level for brevity; the real DSL nests
  them — and the `domain` — inside the `context do … end` section, the ordinary
  Spark shape. The section macros are only in scope inside the block, and Spark
  drops a non-literal `use`-line option, so `domain` is declared in the block.)

  ## The load-bearing invariant — plumbing rides underneath UNCHANGED

  A context translates *only the ubiquitous language*. The inherited infrastructure
  (vault · catalog · org-scope · audit · crypto-shred) stays underneath, unchanged,
  because a context NEVER re-implements an action or copies a resource: it routes
  through the underlying kernel resource's own actions and policies. So:

    * an **aliased action** is the kernel action run against the kernel resource —
      the kernel's `OrgScope` policy still filters, its PII still masks, its audit
      writers still fire. An alias re-names; it cannot re-authorize.
    * a **reshape** adds *derived* calculations (Ash expression calculations loaded
      ad-hoc at query time) — it reads the kernel resource's existing columns and
      computes over them. It can NEVER declare a physical column, an attribute, a
      relationship, or storage. The kernel table is untouched; the reshape lives in
      the vertical's bounded context.

  This is exactly the vision-doc calibration: *"you inherit the plumbing and a
  faster context to build in; you still author the domain."* The rename and the
  billing reshape live in the vertical's context; the plumbing stays underneath.

  ## `alias_resource` — the aliased resource module

  `alias_resource Core.Activity, as: Lumen.Encounter` records the mapping and lets
  you build queries/changesets against the vertical name that execute against the
  kernel resource:

      # These two are equivalent — same kernel actions, same policies, same audit.
      Lumen.Context.query(Lumen.Encounter)     # → Ash.Query for Core.Activity
      Lumen.Context.kernel_resource(Lumen.Encounter)  # → Core.Activity

  The alias is a *name*, not a new resource — it deliberately does NOT define a
  second Ash resource, precisely so the kernel's policies/vault/audit cannot be
  bypassed or widened. A red-path test proves an aliased read is still org-scoped.

  ## `reshape` — derived money, computed correctly

  `reshape` calculations are Ash **expression calculations** (`expr(...)`) applied
  to the kernel resource at query time via `Ash.Query.calculate/8` — the same
  `Ash.Resource.Calculation.Expression` module Ash's own `calculate` DSL entity
  compiles to. `Samen.Context.load(context, alias_or_resource, query)` loads every
  reshape calc for that resource onto a query; the values come back on each record:

      Lumen.Encounter  # aliased
      Core.Invoice     # or the kernel resource directly
      |> Lumen.Context.reshaped_query()
      |> Ash.read!(actor: scope)
      # each record now carries :patient_responsibility and :payer_claim

  ### The `:money` type

  The doc writes `calculate :patient_responsibility, :money, …`. Ash has no
  built-in `:money` type and `AshMoney` is not a substrate dependency, so
  `Samen.Context` maps the DSL-level `:money` shorthand to `:decimal` (the money
  representation the substrate already carries — `decimal` is an Ash/Ecto dep).
  A host that adds `AshMoney` can pass its type module directly; `:money` is sugar,
  documented here as a seam.

  ## Introspection — the catalog knows the alias mapping

  A context is introspectable (plan T3.10 (c)). The representation (decided here,
  documented): `Samen.Context.Info` exposes

    * `aliases/1`  → `[%{alias: Lumen.Encounter, resource: Core.Activity}]`
    * `reshapes/1` → `[%{resource: Core.Invoice, calculations: [%{name:, type:, …}]}]`
    * `catalog_context_map/1` → a flat, machine-readable map of the whole context
      map (alias renames + reshape calc names + their kernel table) suitable for the
      LLM-grounding catalog. This is a *virtual* catalog surface: it names logical
      derived fields (`patient_responsibility`) and their kernel table
      (`inv_invoice`), NOT physical columns — a reshape never mints a column, so it
      never mints a `fld_field` row. The catalog thus distinguishes "physical column"
      (`fld_field`) from "context-derived field" (this map). Documented so a reader
      never mistakes a reshape for storage.
  """

  # `Samen.Context` is the DSL *entry point*: `use Samen.Context` is a `use Spark.Dsl`
  # under the hood, wiring the `Samen.Context.Dsl` extension (the `context do … end`
  # section) into the caller. The vertical's `domain` is declared inside the
  # `context` block (`context do domain X; … end`) — see `Samen.Context.Dsl`.
  #
  # (Aside on the doc's `use Samen.Context, domain: X` shape: Spark's generated
  # `__using__` drops any NON-LITERAL `use` option, and `domain: Some.Module` is an
  # alias AST — not a literal — so a `use`-line domain cannot survive to be captured.
  # Declaring `domain` inside the `context` block is the faithful, working shape; the
  # macro cannot both provide the section macros AND intercept a non-literal opt.)
  use Spark.Dsl, default_extensions: [extensions: [Samen.Context.Dsl]]

  # ===========================================================================
  # Runtime surface — the anti-corruption layer helpers
  # ===========================================================================

  @doc """
  The kernel resource a name refers to. If `name` is an alias declared in
  `context`, returns the aliased kernel resource; otherwise returns `name`
  unchanged (so callers can pass either the alias or the kernel resource).
  """
  @spec kernel_resource(module(), module()) :: module()
  def kernel_resource(context, name) do
    case Enum.find(Samen.Context.Info.aliases(context), &(&1.alias == name)) do
      nil -> name
      %{resource: resource} -> resource
    end
  end

  @doc """
  Build an `Ash.Query` for an alias or kernel resource. The query targets the
  KERNEL resource, so the kernel's actions/policies (org-scope), vault masking,
  and audit ride underneath unchanged — the alias only renames.
  """
  @spec query(module(), module()) :: Ash.Query.t()
  def query(context, name) do
    context |> kernel_resource(name) |> Ash.Query.new()
  end

  @doc """
  Build a query for an alias/kernel resource with EVERY reshape calculation for
  that kernel resource loaded ad-hoc. The derived money fields come back on each
  record. Reads existing columns only; the kernel table is untouched.
  """
  @spec reshaped_query(module(), module()) :: Ash.Query.t()
  def reshaped_query(context, name) do
    context
    |> query(name)
    |> load_reshape(context, name)
  end

  @doc """
  Load every reshape calculation for `name`'s kernel resource onto `query`. Each
  calc is applied via `Ash.Query.calculate/8`, passing the Ash expression directly
  as the `module_and_opts` argument — Ash wraps it in
  `Ash.Resource.Calculation.Expression`, the same module its own `calculate` DSL
  entity compiles to. (Passing an already-wrapped `{Expression, expr: …}` tuple
  double-wraps and blows up in the SQL layer — the raw expression is correct.)
  """
  @spec load_reshape(Ash.Query.t(), module(), module()) :: Ash.Query.t()
  def load_reshape(query, context, name) do
    resource = kernel_resource(context, name)

    context
    |> Samen.Context.Info.calculations_for(resource)
    |> Enum.reduce(query, fn calc, q ->
      Ash.Query.calculate(q, calc.name, resolve_type(calc.type), calc.expr)
    end)
  end

  @doc """
  Resolve a DSL-level calc type to an Ash type. `:money` is sugar for `:decimal`
  (AshMoney is not a substrate dep). Any other value passes through unchanged.
  """
  @spec resolve_type(term()) :: term()
  def resolve_type(:money), do: :decimal
  def resolve_type(other), do: other

  @doc false
  # Re-export so Info can key on the raw section without a hard alias.
  def __section__, do: [:context]
end
