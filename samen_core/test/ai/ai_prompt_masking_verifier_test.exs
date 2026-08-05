defmodule LeakyPromptFixture do
  @moduledoc "A stub Prompt resource whose template body embeds a raw vt_ token — must be flagged."
  def samen_ai_prompt_template_bodies do
    [{:welcome, "Hello — your token is vt_" <> String.duplicate("a", 32)}]
  end
end

defmodule CleanPromptFixture do
  @moduledoc "A stub Prompt resource with a clean template body — must NOT be flagged."
  def samen_ai_prompt_template_bodies do
    [{:welcome, "Hello — how can I help with your account?"}]
  end
end

defmodule Mix.Tasks.Samen.Verify.AiPromptMaskingTest do
  @moduledoc """
  The STRUCTURAL half of the `ai_prompt_masking` verifier tier (ADR-043 §3.4). Proves the
  (b) embeddable-vault cross-check and the (c) Prompt-body vt_ scan are non-vacuous (they flip
  on a modeled leak) AND green on clean input — the anti-tautology discipline. The runtime
  INV-7 red-team is `Samen.AI.AiPromptMaskingRedTeamTest`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Verify.AiPromptMasking, as: V

  @vault_resource SamenCore.Support.RevealDomain.RevealPerson

  describe "(c) Prompt-body vt_ scan" do
    test "a template body embedding a vt_ token is a violation (sabotage-refutable)" do
      assert [msg] = V.prompt_body_vt_violations([LeakyPromptFixture])
      assert msg =~ "vt_"
      assert msg =~ "LeakyPromptFixture"
    end

    test "a clean template body is not flagged (the scan is not blanket-failing)" do
      assert V.prompt_body_vt_violations([CleanPromptFixture]) == []
    end

    test "a resource with no Prompt seam is inert (green-and-real today)" do
      assert V.prompt_body_vt_violations([Enum]) == []
    end
  end

  describe "(b) embeddable-vault cross-check" do
    test "an embeddable field that is vault-routed is a violation (sabotage-refutable)" do
      # RevealPerson declares its vault-routed :emails field embeddable (the modeled leak).
      assert [msg] = V.embeddable_vault_violations([@vault_resource])
      assert msg =~ "vault-routed"
      assert msg =~ "RevealPerson"
    end

    test "a resource with no embeddable seam is inert" do
      assert V.embeddable_vault_violations([Enum]) == []
    end
  end
end
