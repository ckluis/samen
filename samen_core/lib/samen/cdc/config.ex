defmodule Samen.Cdc.Config do
  @moduledoc """
  Opt-in / default-off wiring for the CDC analytics tier (plan T6.5; doc line 635
  "opt-in per product, default off. Most products never turn it on.").

  A host enables the mirror by wiring:

      config :samen_core, :cdc,
        adapter: Samen.Cdc.LocalPostgres,   # or Samen.Cdc.ClickHouse in prod
        repo: MyApp.CdcRepo                  # the second (ecto_ch) repo

  With NO `:cdc` config (the default), the tier is OFF:

    * `Samen.Cdc.enabled?/0` is false;
    * nothing mirrors (`ensure_mirror_for/1` and `mirror/3` are no-ops);
    * the destruction oracle's `cdc_mirror` tier emits a `:pass` saying the mirror
      is not enabled in this deployment.

  ## Back-compat with the T2.9 stub seam

  The T2.9 `CdcMirror` stub checked `config :samen_core, :cdc_mirror_repo`. That
  legacy key is still honored: if it is set (and `:cdc` is not), the tier treats
  the mirror as "configured but no adapter" and fails closed — a configured-but-
  unscanned mirror is a gap, not a pass. Prefer the `:cdc` keyword going forward.
  """

  @doc "The `:cdc` config keyword list (or `[]` when unset)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:samen_core, :cdc, [])

  @doc """
  Is the CDC tier enabled? True iff a `:cdc` adapter is wired. Default off.

  The legacy `:cdc_mirror_repo` key does NOT enable the tier by itself — it only
  makes the oracle fail closed on a configured-but-unscanned mirror (see
  `legacy_mirror_configured?/0`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(adapter())

  @doc "The configured adapter module, or `nil`."
  @spec adapter() :: module() | nil
  def adapter, do: Keyword.get(config(), :adapter)

  @doc """
  The configured CDC (analytics/ecto_ch) repo, or `nil`.

  Falls back to the legacy `:cdc_mirror_repo` key for back-compat.
  """
  @spec repo() :: module() | nil
  def repo do
    Keyword.get(config(), :repo) || Application.get_env(:samen_core, :cdc_mirror_repo)
  end

  @doc """
  Whether the legacy `:cdc_mirror_repo` key is set while the `:cdc` adapter is NOT
  wired — a configured-but-unscanned mirror the oracle must fail closed on.
  """
  @spec legacy_mirror_configured?() :: boolean()
  def legacy_mirror_configured? do
    not enabled?() and not is_nil(Application.get_env(:samen_core, :cdc_mirror_repo))
  end

  @doc "The schema/database name the local-simulation adapter mirrors into."
  @spec schema() :: String.t()
  def schema, do: Keyword.get(config(), :schema, "cdc_mirror")
end
