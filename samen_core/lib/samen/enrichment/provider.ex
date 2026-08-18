defmodule Samen.Enrichment.Provider do
  @moduledoc """
  The core-defined **enrichment provider contract** (spec §I8, T80) — the external
  data enrichment seam. Same shape, same honesty discipline, and the same INV-4
  boundary as `Samen.Delivery.Provider` (ADR-038 §4/§8): `samen_core` defines
  the behaviour, the honest `Samen.Enrichment.FakeProvider` double, and the whole
  enrichment pipeline. It references NO vendor module and pulls NO HTTP/SaaS
  dependency — a real adapter is a SEPARATE package, behind an explicit host flag,
  and is NEVER exercised in CI.

  A host selects an enrichment provider through the application config:

      config :samen_core, :enrichment_provider, {MyEnrichmentAdapter.Provider, %{api_key: "..."}}

  ## The fail-honest contract (ADR-014/024/026 shape, binding)

  Every callback except `configured?/1` and `redact_payload/1` returns
  `{:error, :not_configured}` when `configured?/1` is `false` for the same
  config — NEVER a fabricated enrichment, never a synthesized empty `%{}`.
  An UNCONFIGURED enrichment provider is not an empty enrichment: a surface
  that renders an empty enriched profile for a provider that never ran is the
  exact lie the gates sabotage-test for. A capability the provider genuinely
  lacks (undeclared in `capabilities/0`) returns `{:error, :not_implemented}`.

  ## `use Samen.Enrichment.Provider` — the minimal two-function adapter

  `use Samen.Enrichment.Provider` injects overridable, fail-honest defaults for
  `capabilities/0` (`[]`) and `redact_payload/1` (identity pass-through — honest,
  since an adapter declaring no capability never receives a raw vendor payload to
  redact). A minimal adapter therefore implements only `configured?/1` and
  `enrich/3`.

  ## Callback roster

  See `docs/guides/enrichment-seam.md` — it names every callback, its arguments,
  its honest refusals, and what a real external-data enrichment adapter must do.
  """

  @typedoc "The bounded, honestly-declared capability enum."
  @type capability :: :person_enrich | :company_enrich

  @doc """
  Returns `true` when the provider has everything it needs to actually call the
  external service (API key, endpoint, etc.), `false` otherwise. Every other
  callback (except `redact_payload/1`) MUST refuse with `{:error, :not_configured}`
  when this is `false` for the same `config` — this predicate is the single source
  of truth.
  """
  @callback configured?(config :: map()) :: boolean()

  @doc """
  Honest capability declaration. NOT config-dependent — capabilities are a
  property of the adapter module, not of a runtime config.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Enrich a record (Person or Company) from an external source. Returns
  `{:ok, enriched_data}` ONLY when the provider actually fetched and returned data;
  the data MUST be a map. If the external source has no data for this record,
  return `{:ok, %{}}` (honest empty). An adapter that does not declare the
  required capability (`:person_enrich` for persons, `:company_enrich` for companies)
  returns `{:error, :not_implemented}`.
  """
  @callback enrich(subject_type :: :person | :company, subject_id :: any(), config :: map()) ::
              {:ok, enriched_data :: map()} | {:error, :not_configured | :not_implemented | term()}

  @doc """
  PII pruning of a raw vendor payload BEFORE it is persisted. A pure function —
  it must not need creds or network access, so it is exempt from the
  `configured?/1` fail-honest gate.
  """
  @callback redact_payload(payload :: map()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Samen.Enrichment.Provider

      @impl Samen.Enrichment.Provider
      def capabilities, do: []

      @impl Samen.Enrichment.Provider
      def redact_payload(payload) when is_map(payload), do: payload

      defoverridable capabilities: 0, redact_payload: 1
    end
  end
end
