# Fixtures — opted-in agent-tool modules with a modeled actor/org/tenant identity leak.
# Registered through the sanctioned host-extra seam only for the duration of the tests
# that need them (house discipline, matching ai_prompt_masking_tool_checks_test.exs).
defmodule CleanIdParamTool do
  @moduledoc false
  def kind, do: :clean_id_param
  def tool_schema, do: %{name: "clean_id_param", params: [%{name: "id", type: "string"}]}
  def effect, do: :read
end

defmodule RogueActorIdTool do
  @moduledoc false
  def kind, do: :rogue_actor_id
  def tool_schema,
    do: %{name: "rogue_actor_id", params: [%{name: "actor_id", type: "string"}]}
  def effect, do: :read
end

defmodule RogueOrgIdTool do
  @moduledoc false
  def kind, do: :rogue_org_id
  def tool_schema,
    do: %{name: "rogue_org_id", params: [%{name: "org_id", type: "string"}]}
  def effect, do: :read
end

defmodule RogueTenantParamTool do
  @moduledoc false
  def kind, do: :rogue_tenant_param
  def tool_schema,
    do: %{name: "rogue_tenant_param", params: [%{name: "tenant_id", type: "string"}]}
  def effect, do: :read
end

defmodule RogueUserIdTool do
  @moduledoc false
  # Negative control: `user_id` names a TARGET record (assign_record_owner's shape), not
  # the calling actor's own identity — must NOT be flagged.
  def kind, do: :rogue_user_id
  def tool_schema,
    do: %{name: "rogue_user_id", params: [%{name: "user_id", type: "string"}]}
  def effect, do: :read
end

defmodule Mix.Tasks.Samen.Verify.ToolActorIdentityTest do
  @moduledoc """
  T185 — anti-tautology proof for `mix samen.verify.tool_actor_identity` (ADR-043 §6.2/§7):
  no tool schema, on either shared surface (`Samen.Automation.Action` agent tools,
  `Samen.AI.Mcp` MCP tool catalogue), may declare an actor/org/tenant identity parameter.

  Three layers, the house verifier discipline:
    1. **unit layer — `identity_leak?/1`** — the shared normalization predicate.
    2. **unit layer — the two surface scans** — each modeled defect flips its scan; the
       shipped set (both surfaces) is clean (the positive control that the scans are not
       blanket-failing); a target-record param (`user_id`) is NOT flagged (anti-overreach).
    3. **exit-code layer** — `System.cmd/3` in a child OS process, the only way to observe
       `:erlang.halt(1)` without killing the test VM: the real tree exits 0; the
       `SAMEN_TOOL_ACTOR_IDENTITY_INJECT_PARAM` test seam proves a leaking name flips the
       gate to exit 1 through the REAL `identity_leak?/1` predicate.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.ToolActorIdentity, as: V
  alias Samen.Automation.Action

  @project_dir Path.expand("../../", __DIR__)

  setup do
    previous = Application.get_env(:samen_core, Action, [])
    on_exit(fn -> Application.put_env(:samen_core, Action, previous) end)
    %{previous: previous}
  end

  defp register(extra, %{previous: previous}) do
    Application.put_env(:samen_core, Action, Keyword.put(previous, :extra, extra))
    Samen.AI.Agent.Tools.refresh()
  end

  # ==========================================================================
  # identity_leak?/1 — the shared normalization predicate
  # ==========================================================================

  describe "identity_leak?/1" do
    test "flags bare and compound actor/org/tenant names" do
      for name <- ~w(actor actor_id org org_id organization organization_id tenant tenant_id
                     tenant_org_id ActorId ORG_ID) do
        assert V.identity_leak?(name), "expected #{inspect(name)} to be flagged"
      end
    end

    test "does not flag unrelated business fields" do
      for name <- ~w(id resource query limit user_id record_id reason input prompt verb) do
        refute V.identity_leak?(name), "expected #{inspect(name)} NOT to be flagged"
      end
    end

    # ==========================================================================
    # UXD-03 (`_orch/verify/T11-verdict.json`'s `strongest_attack`, backlog.yaml:195) —
    # the original literal token set (`actor`/`org`/`organization`/`tenant`) let
    # identity-shaped names OUTSIDE it pass: `on_behalf_of`, `account_id`, `acting_as`,
    # `as_user` all returned `false`. Widened to also match `account`/`behalf`/`as`.
    # `user_id` (assign_record_owner's TARGET-record field) must keep passing — the
    # sparing is deliberate and must survive the widening (pinned below and in the
    # existing "does not flag unrelated business fields" test above).
    # ==========================================================================
    test "RED FIXTURE (UXD-03) — identity-shaped names outside the old token set are flagged" do
      for name <- ~w(on_behalf_of account_id acting_as as_user onBehalfOf accountId actingAs asUser) do
        assert V.identity_leak?(name), "expected #{inspect(name)} to be flagged (UXD-03)"
      end
    end

    test "UXD-03 widening does not disturb the deliberate user_id sparing" do
      refute V.identity_leak?("user_id")
      refute V.identity_leak?("userId")
    end

    test "UXD-03 OVER-approximation is documented, accepted and pinned (fail-closed direction)" do
      # `_orch/verify/T11-verdict-attempt3.json` judged this ACCEPTABLE, not a defect: the
      # bare `as` token also matches names that merely tokenize to it. Recorded here so the
      # moduledoc's "Known OVER-approximation, accepted" note is TESTED, not just asserted —
      # if a later narrowing changes this behaviour, that note must be updated in the same
      # commit. The spared TARGET-record fields stay false in the same breath.
      for name <- ~w(same_as known_as as_of as_of_date base_as) do
        assert V.identity_leak?(name), "expected the accepted over-approximation on #{inspect(name)}"
      end

      for name <- ~w(user_id userId record_id owner_id assignee_id target_user_id task_id document_id) do
        refute V.identity_leak?(name), "the deliberate TARGET-record sparing broke on #{inspect(name)}"
      end
    end

    test "does not flag non-binary/atom input" do
      refute V.identity_leak?(nil)
      refute V.identity_leak?(%{})
      refute V.identity_leak?(123)
    end
  end

  # ==========================================================================
  # (Action registry) surface — clean shipped set + each defect flips
  # ==========================================================================

  describe "Samen.Automation.Action tool-schema scan — clean shipped set" do
    test "the shipped agent tools carry no actor/org/tenant identity param" do
      assert V.action_tool_violations() == []
    end
  end

  describe "Samen.Automation.Action tool-schema scan — each defect flips" do
    test "an actor_id param is a violation (sabotage-refutable)", ctx do
      register(%{"rogue_actor_id" => RogueActorIdTool}, ctx)
      assert Enum.any?(V.action_tool_violations(), &(&1 =~ "actor_id"))
    end

    test "an org_id param is a violation", ctx do
      register(%{"rogue_org_id" => RogueOrgIdTool}, ctx)
      assert Enum.any?(V.action_tool_violations(), &(&1 =~ "org_id"))
    end

    test "a tenant_id param is a violation", ctx do
      register(%{"rogue_tenant_param" => RogueTenantParamTool}, ctx)
      assert Enum.any?(V.action_tool_violations(), &(&1 =~ "tenant_id"))
    end

    test "a clean id param is NOT flagged (the scan is not blanket-failing)", ctx do
      register(%{"clean_id_param" => CleanIdParamTool}, ctx)
      refute Enum.any?(V.action_tool_violations(), &(&1 =~ "clean_id_param"))
    end

    test "a target-record user_id param is NOT flagged (anti-overreach)", ctx do
      register(%{"rogue_user_id" => RogueUserIdTool}, ctx)
      refute Enum.any?(V.action_tool_violations(), &(&1 =~ "user_id"))
    end
  end

  # ==========================================================================
  # MCP tool catalogue surface — clean shipped set
  # ==========================================================================

  describe "Samen.AI.Mcp tool catalogue scan" do
    test "the shipped MCP tools (browse/search/drafts/action_proposals) carry no " <>
           "actor/org/tenant identity property" do
      assert V.mcp_tool_violations() == []
    end
  end

  # ==========================================================================
  # Exit-code layer — the true :erlang.halt code (house discipline)
  # ==========================================================================

  describe "exit-code layer (System.cmd/3)" do
    @tag :exit_code
    test "the real tree exits 0" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_actor_identity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert code == 0, "expected the shipped tree to pass; output:\n#{output}"
      assert output =~ "OK — no violations"
    end

    @tag :exit_code
    test "RED PATH: the injected-param seam flips the gate to exit 1" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_actor_identity"],
          cd: @project_dir,
          env: [
            {"MIX_ENV", "test"},
            {"SAMEN_TOOL_ACTOR_IDENTITY_INJECT_PARAM", "org_id"}
          ],
          stderr_to_stdout: true
        )

      assert code == 1, "expected exit 1 on the injected identity param; output:\n#{output}"
      assert output =~ "org_id"
      assert output =~ "ctx[:actor]"
    end

    @tag :exit_code
    test "the injected-param seam does NOT flip on a clean name (anti-tautology)" do
      {output, code} =
        System.cmd("mix", ["samen.verify.tool_actor_identity"],
          cd: @project_dir,
          env: [
            {"MIX_ENV", "test"},
            {"SAMEN_TOOL_ACTOR_IDENTITY_INJECT_PARAM", "resource_id"}
          ],
          stderr_to_stdout: true
        )

      assert code == 0,
             "expected a clean injected name NOT to flip the gate; output:\n#{output}"
    end
  end
end
