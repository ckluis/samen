defmodule Samen.HostDomains do
  @moduledoc """
  The host's domain registry: the Ash domains the samen_core verifiers, catalog, MCP surface, data map and
  erasure sweeps discover resources from. A host sets it in `config/config.exs`:

      config :samen_core, :host_domains, [MyApp.Billing, MyApp.Vertical]

  It is NOT `:ash_domains`. `:samen_core, :ash_domains` is Ash's own key for the `:samen_core` application:
  `Ash.Resource.verify` reads it while samen_core's resources compile as a dependency of the host, and a host
  domain that is not compiled yet then raises `... is not a Spark DSL module` (nine warning blocks per host
  build) and the domain-inclusion check is skipped. samen_core's own build still runs that check against its own
  `:ash_domains`. A host's OWN `config :my_app, ash_domains: [...]` is unchanged (Ash's convention for the host).

  ## Upgrade

  Rename `config :samen_core, :ash_domains, [...]` to `config :samen_core, :host_domains, [...]`. For one release
  the old key is still read when `:host_domains` is not configured, with a deprecation warning, so an
  un-renamed host does not silently see an EMPTY registry (several verifiers fail on zero resources; that stays).
  """

  require Logger

  @doc "The registered host domains (de-duplicated, in order). `[]` only when nothing is configured at all."
  @spec registry() :: [module()]
  def registry do
    case Application.fetch_env(:samen_core, :host_domains) do
      {:ok, domains} when is_list(domains) -> Enum.uniq(domains)
      _ -> legacy()
    end
  end

  # The pre-rename key, read only when the new one is absent, and loudly (once per VM).
  defp legacy do
    case Application.get_env(:samen_core, :ash_domains, []) do
      [] ->
        []

      domains when is_list(domains) ->
        warn_once()
        Enum.uniq(domains)

      _ ->
        []
    end
  end

  defp warn_once do
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "[Samen.HostDomains] `config :samen_core, :ash_domains` is deprecated: rename it to " <>
          "`config :samen_core, :host_domains` (the old key is Ash's own and makes host builds print " <>
          "\"is not a Spark DSL module\" warnings). It is read as a fallback for this release only."
      )
    end

    :ok
  end
end
