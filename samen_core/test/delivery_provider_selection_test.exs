defmodule Samen.Delivery.ProviderSelectionTest do
  @moduledoc """
  ADR-038 §4.3 — `Samen.Delivery.ProviderSelection` per-host-default / per-org
  override chokepoint. T27's binding "two-fake selection test": two DISTINCT
  fake provider modules prove module-level selection (not just config-value
  selection on a single module), plus the ADR-024 `--deploy`-precedent
  fail-closed raise on misconfiguration.
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.ProviderSelection
  alias Samen.Delivery.ProviderSelection.ConfigError

  # Two DISTINCT, real Provider-conformant fakes (module-level distinctness is
  # what proves "selection among adapters", not merely "selection among configs").
  defmodule FakeA do
    use Samen.Delivery.Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(_message, _config), do: {:ok, %{provider_message_id: "a-1", via: :fake_a}}
  end

  defmodule FakeB do
    use Samen.Delivery.Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(_message, _config), do: {:ok, %{provider_message_id: "b-1", via: :fake_b}}
  end

  defmodule NotAProvider do
    def hello, do: :world
  end

  setup do
    prev_default = Application.get_env(:samen_core, :delivery_provider)
    prev_overrides = Application.get_env(:samen_core, :delivery_provider_overrides)

    on_exit(fn ->
      restore(:delivery_provider, prev_default)
      restore(:delivery_provider_overrides, prev_overrides)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  describe "host default only" do
    test "resolves the host default when no org override is configured" do
      Application.put_env(:samen_core, :delivery_provider, {FakeA, %{server_token: "x"}})

      assert {FakeA, %{server_token: "x"}} = ProviderSelection.resolve!("org-1")
      assert {FakeA, %{server_token: "x"}} = ProviderSelection.resolve!(nil)
    end

    test "returns nil when nothing is configured anywhere (honest, never a fabricated fallback)" do
      Application.delete_env(:samen_core, :delivery_provider)
      Application.delete_env(:samen_core, :delivery_provider_overrides)

      assert ProviderSelection.resolve!("org-1") == nil
      assert ProviderSelection.resolve!(nil) == nil
    end
  end

  describe "per-org override (the two-fake selection test)" do
    test "an org with an override resolves to ITS module, a different org falls back to the host default" do
      Application.put_env(:samen_core, :delivery_provider, {FakeA, %{server_token: "host-default"}})

      Application.put_env(:samen_core, :delivery_provider_overrides, %{
        "org-special" => {FakeB, %{api_key: "org-override"}}
      })

      assert {FakeB, %{api_key: "org-override"}} = ProviderSelection.resolve!("org-special")
      assert {FakeA, %{server_token: "host-default"}} = ProviderSelection.resolve!("org-other")
      assert {FakeA, %{server_token: "host-default"}} = ProviderSelection.resolve!(nil)
    end

    test "the two resolved modules genuinely dispatch differently (anti-tautology, not just distinct atoms)" do
      Application.put_env(:samen_core, :delivery_provider, {FakeA, %{}})
      Application.put_env(:samen_core, :delivery_provider_overrides, %{"org-1" => {FakeB, %{}}})

      {mod_a, cfg_a} = ProviderSelection.resolve!("org-2")
      {mod_b, cfg_b} = ProviderSelection.resolve!("org-1")

      assert {:ok, %{via: :fake_a}} = mod_a.deliver(:irrelevant, cfg_a)
      assert {:ok, %{via: :fake_b}} = mod_b.deliver(:irrelevant, cfg_b)
    end
  end

  describe "fail-closed on misconfiguration (ADR-024 --deploy precedent)" do
    test "raises when the host default is not a {module, config} tuple" do
      Application.put_env(:samen_core, :delivery_provider, :not_a_tuple)

      assert_raise ConfigError, fn -> ProviderSelection.resolve!(nil) end
    end

    test "raises when the host default module does not implement Samen.Delivery.Provider" do
      Application.put_env(:samen_core, :delivery_provider, {NotAProvider, %{}})

      assert_raise ConfigError, fn -> ProviderSelection.resolve!(nil) end
    end

    test "raises when an org override is malformed, even though the host default is fine" do
      Application.put_env(:samen_core, :delivery_provider, {FakeA, %{}})
      Application.put_env(:samen_core, :delivery_provider_overrides, %{"org-bad" => {NotAProvider, %{}}})

      assert_raise ConfigError, fn -> ProviderSelection.resolve!("org-bad") end
      # A DIFFERENT org, unaffected by the bad override, still resolves cleanly.
      assert {FakeA, %{}} = ProviderSelection.resolve!("org-fine")
    end

    test "never silently falls through to :blocked on a malformed entry (raise, not nil)" do
      Application.put_env(:samen_core, :delivery_provider, {NotAProvider, %{}})

      # If misconfiguration degraded to `nil` (the honest "nothing wired" case),
      # this would look identical to "nothing configured" — masking an operator
      # mistake as if it were a deliberate absence. It must raise instead.
      assert_raise ConfigError, fn -> ProviderSelection.resolve!(nil) end
    end
  end
end
