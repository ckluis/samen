defmodule Samen.Delivery.ProviderSelection do
  @moduledoc """
  ADR-038 §4.3 chokepoint: resolves WHICH `Samen.Delivery.Provider` adapter
  module (+ its config) a send should route through, supporting a per-host
  default with an optional per-org override among the three first-party ESP
  adapter packages (ADR-038 §8.1) or any other conformant adapter (`Smtp`/
  `LocalSink` included).

  ## Config shape

      config :samen_core, :delivery_provider, {MyEspAdapter.Provider, %{api_key: "..."}}

      config :samen_core, :delivery_provider_overrides, %{
        "org_123" => {MyOtherEspAdapter.Provider, %{api_key: "..."}}
      }

  `resolve!/1` returns the org override when one is configured for `org_id`,
  else the host default, else `nil` (nothing configured anywhere — the honest
  "not wired" case; callers treat a `nil` result exactly like ADR-014's
  `:blocked` path, this module never fabricates a fallback).

  ## Fail-closed on misconfiguration (ADR-024 `--deploy` precedent)

  A malformed entry — not a `{module, config}` 2-tuple, or a module that does
  not implement `Samen.Delivery.Provider` (missing `configured?/1`/`deliver/2`)
  — RAISES `Samen.Delivery.ProviderSelection.ConfigError` at resolve time,
  immediately, rather than silently falling through to `:blocked`. `samen_core`
  is a library (it has no boot sequence of its own): the raise fires the moment
  a host consults this config, mirroring the generated `config/runtime.exs`
  fail-closed-on-missing-secret precedent (ADR-024) — a host wires
  `resolve!/1` at ITS OWN boot/first-use point to get the same "fail before
  serving traffic" property a real release gets from `runtime.exs`.

  ## Wired into every send path (T28/C2 — this GAP is now closed)

  `Samen.Delivery.Chokepoint.resolve_provider/3` (ADR-038 §4.3, T28) consults
  `resolve!/1` FIRST for every send — `Samen.Scopes.Marketing.SendWorker`,
  `Samen.Delivery.Lifecycle.EmailWorker`, `Samen.Delivery.AuthMailer`, and
  `Samen.Notifications.EmailDispatchWorker` all route through the chokepoint
  rather than resolving+calling an adapter directly, so an org-level override
  configured here is now honored end-to-end. Each worker's LEGACY per-worker
  `resolve_adapter/0`/`adapter_config/0` config stays as the chokepoint's
  FALLBACK for hosts that wired that instead (or never wired `:delivery_provider`
  at all) — `resolve!/1` returning `nil` (nothing configured anywhere) is what
  triggers that fallback; a malformed entry still raises `ConfigError`
  immediately, it is never masked by the fallback.
  """

  defmodule ConfigError do
    defexception [:message]
  end

  @doc """
  Resolve the `{module, config}` a send for `org_id` should use. `org_id` is
  optional (`nil` resolves the host default only). Raises `ConfigError` on a
  malformed entry. Returns `nil` when nothing is configured anywhere.
  """
  @spec resolve!(String.t() | nil) :: {module(), map()} | nil
  def resolve!(org_id \\ nil) do
    case org_override(org_id) do
      nil -> host_default()
      entry -> validate!(entry, {:org_override, org_id})
    end
  end

  defp org_override(nil), do: nil

  defp org_override(org_id) do
    :samen_core
    |> Application.get_env(:delivery_provider_overrides, %{})
    |> Map.get(org_id)
  end

  defp host_default do
    case Application.get_env(:samen_core, :delivery_provider) do
      nil -> nil
      entry -> validate!(entry, :host_default)
    end
  end

  defp validate!({module, config}, _source) when is_atom(module) and is_map(config) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :configured?, 1) and
             function_exported?(module, :deliver, 2) do
      raise ConfigError,
        message:
          "Samen.Delivery.ProviderSelection: #{inspect(module)} does not implement " <>
            "Samen.Delivery.Provider (missing configured?/1 or deliver/2)"
    end

    {module, config}
  end

  defp validate!(other, source) do
    raise ConfigError,
      message:
        "Samen.Delivery.ProviderSelection: malformed delivery_provider entry for " <>
          "#{inspect(source)} — expected {module, config_map}, got #{inspect(other)}"
  end
end
