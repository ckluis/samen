defmodule Samen.Verifiers.EmbeddableNoPii do
  @moduledoc """
  Compile-time Spark verifier — a vault-routed (🔒) field declared `embeddable` FAILS THE
  BUILD (ADR-043 §7.2, D3/T67; the `Samen.Verifiers.TntBoundary` precedent that a Spark
  verifier reliably aborts a `use Samen.Resource` compile).

  ## The invariant (§7.2 — grants NEVER unlock embedding)

  Embedding input is allowlist-by-construction: a field enters vector space ONLY if it is
  declared `embeddable` (the `samen` section, usually `use Samen.Resource, embeddable: [...]`).
  A vault-routed value must NEVER be embeddable — not even under a reveal grant — because a
  vector **persists beyond any grant window and is invertible**: embedding a vaulted field
  would leak PII into vector space permanently, defeating crypto-shred (ADR-001 — the vector
  would survive the subject key's destruction). INV-7's ephemeral-only clause is categorical
  here, so this is enforced at the earliest possible point: compile.

  ## The three layers this is the FIRST of

    1. **compile-time (this verifier)** — a `use Samen.Resource, embeddable: [🔒field]`
       resource does not compile, in any host, in any plane. Structurally un-embeddable via
       the sanctioned DSL path.
    2. **structural ci.sh** — `mix samen.verify.ai_prompt_masking` (b) cross-checks EVERY
       `embeddable_fields/0` (including a hand-written laundering `def`, which this compile
       verifier cannot see) against `Samen.Pii.Info.vault_routed_columns/1` + the pii logical
       names. The backstop for a seam that bypasses the DSL.
    3. **runtime** — `Samen.AI.Chokepoint` refuses a vault-routed `:embed` binding fail-closed
       (`{:error, :pii_egress_refused}`), and the `Samen.AI.Embeddings` plane routes every
       embed through it.

  ## Inert by default (zero blast radius)

  The check reads the `samen` section's `embeddable` list; empty (the default for every
  resource that does not opt in) ⇒ `:ok` immediately. Only a resource that BOTH declares an
  embeddable field AND that field is vault-routed fails — a state no shipped resource is in.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    embeddable = Verifier.get_option(dsl_state, [:samen], :embeddable, [])

    if embeddable == [] do
      :ok
    else
      module = Verifier.get_persisted(dsl_state, :module)

      case offending_field(embeddable, pii_field_names(dsl_state)) do
        nil -> :ok
        field -> {:error, Spark.Error.DslError.exception(dsl_error_opts(module, field))}
      end
    end
  end

  @doc """
  The pure detection: the first embeddable field that is vault-routed, or `nil` if none.
  Public so the non-vacuity red path can prove BOTH directions (a 🔒 field flags; a clean
  field does not) WITHOUT a scratch compile — the `mix samen.verify.*` `violations/1` idiom.
  """
  @spec offending_field([atom()], [atom()]) :: atom() | nil
  def offending_field(embeddable, pii_names) do
    Enum.find(embeddable, &(&1 in pii_names))
  end

  @doc "The `Spark.Error.DslError` opts for a vault-routed embeddable `field` (public for the test)."
  @spec dsl_error_opts(module(), atom()) :: keyword()
  def dsl_error_opts(module, field) do
    [
      module: module,
      path: [:samen, :embeddable],
      message:
        "resource #{inspect(module)} declares vault-routed (🔒) field #{inspect(field)} as " <>
          "`embeddable`. A vault-routed value must NEVER enter vector space (ADR-043 §7.2): a " <>
          "vector persists beyond any reveal grant and is invertible, so grants never unlock " <>
          "embedding and embedding a vaulted field would defeat crypto-shred (ADR-001). Drop " <>
          "#{inspect(field)} from the `embeddable` set, or de-vault the field. Deny-by-default " <>
          "is by construction."
    ]
  end

  # The logical names of every vault-routed (`pii_attribute`) field on the resource — read
  # from the DECLARATION (the `pii` section entities), never a storage-column heuristic, so it
  # matches `Samen.Pii.Info` exactly. The DSL state form is used (the resource is mid-compile).
  defp pii_field_names(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:pii])
    |> Enum.filter(&match?(%Samen.Pii.Attribute{}, &1))
    |> Enum.map(& &1.name)
  end
end
