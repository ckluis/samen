defmodule Samen.Enrichment do
  @moduledoc """
  Enrichment facade (spec §I8, T80). Coordinates enrich operations with the
  configured provider, with honest empty-state handling when unconfigured.
  """

  alias Samen.Enrichment.FakeProvider

  @doc """
  Enrich a Person or Company from the configured provider. Returns
  `{:ok, enriched_data}` when successful (even if enriched_data is empty `%{}`),
  or `{:error, reason}` on failure or if unconfigured.
  """
  def enrich(subject_type, subject_id) when subject_type in [:person, :company] do
    {provider_mod, config} = provider_selection()

    if provider_mod.configured?(config) do
      provider_mod.enrich(subject_type, subject_id, config)
    else
      {:error, :not_configured}
    end
  end

  @doc "Check if the enrichment provider is configured and ready."
  def provider_configured? do
    {provider_mod, config} = provider_selection()
    provider_mod.configured?(config)
  end

  @doc "Return the selected provider module and its config."
  def provider_selection do
    case Application.get_env(:samen_core, :enrichment_provider, {FakeProvider, %{}}) do
      {mod, config} when is_atom(mod) and is_map(config) ->
        {mod, config}

      {mod, config} ->
        {mod, config || %{}}

      _ ->
        {FakeProvider, %{}}
    end
  end
end
