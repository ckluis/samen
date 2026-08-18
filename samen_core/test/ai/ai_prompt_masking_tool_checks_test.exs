# Fixtures — opted-in agent-tool modules with a modeled defect each. Registered through the
# sanctioned host-extra seam only for the duration of the tests that need them.
defmodule BoundedTool do
  @moduledoc false
  def kind, do: :bounded_ok
  def tool_schema, do: %{name: "bounded_ok", params: [%{name: "id", type: "string"}]}
  def effect, do: :read
end

defmodule UnboundedTool do
  @moduledoc false
  def kind, do: :unbounded
  # A pid leaf — not a bounded scalar; a tool def is EG2 egress and must be bounded.
  def tool_schema, do: %{name: "unbounded", handle: :erlang.list_to_pid(~c"<0.0.0>")}
  def effect, do: :read
end

defmodule VtTokenTool do
  @moduledoc false
  def kind, do: :vt_token
  def tool_schema, do: %{name: "vt_token", hint: "vt_" <> String.duplicate("a", 32)}
  def effect, do: :read
end

defmodule DynamicSchemaTool do
  @moduledoc false
  def kind, do: :dynamic_schema
  # STATICNESS violation: the schema is derived at call time from config/tenant data (a
  # silent EG2 egress on every turn) rather than being a compile-time constant.
  def tool_schema, do: %{name: "dynamic_schema", enum: Application.get_env(:samen_core, :x)}
  def effect, do: :read
end

defmodule NoEffectTool do
  @moduledoc false
  def kind, do: :no_effect
  def tool_schema, do: %{name: "no_effect"}
end

defmodule Mix.Tasks.Samen.Verify.AiPromptMaskingToolChecksTest do
  @moduledoc """
  ADR-047 batch **A7** — the (d) tool-schema boundedness/staticness and (e) tool-eligibility
  INV-7 checks folded into `mix samen.verify.ai_prompt_masking` (§7.2). Each modeled defect
  flips its check (anti-tautology), and the SHIPPED tool set is clean (the positive control
  that the checks are not blanket-failing). Registry-mutating ⇒ `async: false`.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.AiPromptMasking, as: V
  alias Samen.Automation.Action

  setup do
    previous = Application.get_env(:samen_core, Action, [])
    on_exit(fn -> Application.put_env(:samen_core, Action, previous) end)
    %{previous: previous}
  end

  defp register(extra, %{previous: previous}) do
    Application.put_env(:samen_core, Action, Keyword.put(previous, :extra, extra))
    Samen.AI.Agent.Tools.refresh()
  end

  describe "(d) boundedness + staticness — clean shipped set" do
    test "the shipped tools carry no boundedness/staticness violation" do
      assert V.tool_schema_boundedness_violations() == []
    end
  end

  describe "(d) boundedness + staticness — each defect flips" do
    test "an unbounded leaf (a pid) is a violation", ctx do
      register(%{"unbounded" => UnboundedTool}, ctx)
      assert Enum.any?(V.tool_schema_boundedness_violations(), &(&1 =~ "non-bounded leaf"))
    end

    test "a vt_ sentinel in a tool def is a violation", ctx do
      register(%{"vt_token" => VtTokenTool}, ctx)
      assert Enum.any?(V.tool_schema_boundedness_violations(), &(&1 =~ "vt_"))
    end

    test "a tool_schema derived from a live Ash.read is a STATICNESS violation", ctx do
      register(%{"dynamic_schema" => DynamicSchemaTool}, ctx)
      assert Enum.any?(V.tool_schema_boundedness_violations(), &(&1 =~ "compile-time constant"))
    end

    test "a bounded, static tool def is NOT flagged (the check is not blanket-failing)", ctx do
      register(%{"bounded_ok" => BoundedTool}, ctx)
      refute Enum.any?(V.tool_schema_boundedness_violations(), &(&1 =~ "bounded_ok"))
    end
  end

  describe "(e) eligibility — each defect flips; shipped set clean" do
    test "the shipped tool set has no eligibility violation" do
      assert V.tool_eligibility_violations() == []
    end

    test "a tool that omits effect/0 is a violation", ctx do
      register(%{"no_effect" => NoEffectTool}, ctx)
      assert Enum.any?(V.tool_eligibility_violations(), &(&1 =~ "does not export `effect/0`"))
    end

    test "an analytics-named action is structurally ineligible: opting it in flips (e)", ctx do
      # `"webhook"` is a CORE kind (core wins over host-extra, so it cannot be opted in from
      # a test) — the analytics arm of the same exclusion is the reachable positive control.
      register(%{"agent_analytics" => BoundedTool}, ctx)
      assert Enum.any?(V.tool_eligibility_violations(), &(&1 =~ "analytics"))
    end
  end
end
