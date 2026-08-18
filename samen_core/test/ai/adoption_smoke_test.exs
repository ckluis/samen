defmodule Samen.AI.AdoptionSmokeTest do
  @moduledoc """
  ≈0-LOC vertical adoption (ADR-043 §5.3, INV-5). A vertical adopts AI with NO authored
  wiring beyond the host provider config — then any scope calls `Samen.AI.complete/4` and
  gets a completion, routed through the chokepoint, provider-blind. This smoke proves the
  leverage guard: the capability lives in `samen_core`; the host authors ~one line (the
  provider config) and nothing else.
  """
  use ExUnit.Case, async: true

  alias Samen.AI
  alias Samen.AI.Provider

  setup do
    Provider.Fake.reset()
    :ok
  end

  test "a vertical calls the kernel with only a provider config and gets a completion" do
    # The ONE authored line a host/vertical writes (here expressed as an opt; in a real host
    # it is `config :samen_core, Samen.AI, provider: {SamenAnthropic.Provider, %{api_key: ...}}`).
    provider = {Provider.Fake, %{seed: 1}}

    assert {:ok, %AI.Completion{provider: :fake}} =
             AI.complete(:vertical_actor_scope, "draft a follow-up for this account", %{}, provider: provider)

    # Routed through the chokepoint: the provider received a sealed payload, not raw input.
    assert [{:complete, %AI.MaskedPayload{kind: :complete}}] = Provider.Fake.sent_payloads()
  end

  test "with no provider wired anywhere, the keyless :test lane resolves the Fake (no host key needed)" do
    assert {:ok, %AI.Completion{provider: :fake}} = AI.complete(:scope, "hello", %{})
  end
end
