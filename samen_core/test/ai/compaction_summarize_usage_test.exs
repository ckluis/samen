defmodule Samen.AI.Agent.CompactionSummarizeUsageTest do
  @moduledoc """
  Issue #72 — `Samen.AI.Agent.Compaction.summarize/3` reports what the summarize CALL spent,
  as two non-negative integers, on every outcome: a summary that survives ingress, one the
  ingress path refuses, and a provider failure that reported usage. Zero only when nothing
  was spent.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.Agent.Compaction
  alias Samen.AI.Provider.Scripted

  setup do
    Scripted.reset()
    on_exit(&Scripted.reset/0)
  end

  defp summarize(entry) do
    Scripted.script([entry])

    Compaction.summarize(%{plane: :tenant}, ["turn 1: routine"],
      provider: {Scripted, %{}},
      grounding: %{}
    )
  end

  test "a summary that survives ingress carries the call's usage" do
    assert {:ok, "Summary: fine.", %{input_tokens: 30, output_tokens: 4}} =
             summarize({:continue, "Summary: fine.", %{input_tokens: 30, output_tokens: 4}})
  end

  test "a summary ingress refuses still carries what the call spent" do
    # Non-empty, so it reaches the ingress path, which collapses it to nothing.
    assert {:error, :empty_summary, %{input_tokens: 12, output_tokens: 0}} =
             summarize({:continue, "   ", %{input_tokens: 12, output_tokens: 0}})
  end

  test "an empty completion is refused before ingress, and still carries what the call spent" do
    assert {:error, :empty_summary, %{input_tokens: 9, output_tokens: 1}} =
             summarize({:continue, "", %{input_tokens: 9, output_tokens: 1}})
  end

  test "a failure that reported usage carries it" do
    assert {:error, :context_overflow, %{input_tokens: 900, output_tokens: 3}} =
             summarize({:error, :context_overflow, %{input_tokens: 900, output_tokens: 3}})
  end

  test "a failure that reported nothing spent nothing" do
    assert {:error, :provider_error, %{input_tokens: 0, output_tokens: 0}} =
             summarize({:error, :provider_error})
  end

  test "a malformed count is 0, never a guess" do
    assert {:ok, _summary, %{input_tokens: 0, output_tokens: 5}} =
             summarize({:continue, "Summary: x.", %{input_tokens: -4, output_tokens: 5}})
  end
end
