defmodule Samen.AI.AgentConversationPropertyTest do
  @moduledoc """
  ADR-047 §5.2a — the request-shape invariants the Messages API enforces, asserted over MANY
  generated transcripts rather than the hand-built cases in `agent_conversation_test.exs`.

  For every generated conversation (random turn-shape sequences — text / note / call / failed
  call / refused / proposed / approved — random lines including blank ones, vendor and
  synthetic ids drawn from a small pool so they collide, malformed ids, tools that are offered,
  renamed or gone, native and text-envelope providers, and shapes that do not line up with the
  turns), `Conversation.build/4` must return a conversation in which:

    * the first message is `user`, roles alternate, and the last message is `user`;
    * no text block and no tool_result content is empty or whitespace-only;
    * every `tool_call` id is unique, names a tool offered in THIS call, and only appears when
      the provider is native;
    * every `tool_call` is answered by exactly one `tool_result` with its id, at the head of the
      immediately following user message, and no `tool_result` answers anything else;
    * the chokepoint seals it (the closed turn shape holds).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.AI.Agent.Conversation
  alias Samen.AI.Chokepoint

  @pool_ids ["toolu_01A", "toolu_01B", "toolu_samen_turn_1", "toolu_samen_turn_2"]
  @bad_ids ["bad id!", "", String.duplicate("x", 200)]
  @names ["fetch_record", "assign_record_owner", "gone_tool"]
  @kinds ["invalid_args", "invalid_tool_call", "tool_refused", "tool_off_surface", "boom"]

  defp line,
    do:
      one_of([
        constant(""),
        constant("   "),
        constant("\n"),
        string(:printable, min_length: 1, max_length: 12)
      ])

  defp lines, do: list_of(line(), max_length: 3)
  defp id, do: one_of([member_of(@pool_ids), member_of(@bad_ids)])
  defp name, do: member_of(@names)

  defp input,
    do:
      map_of(
        string(:alphanumeric, min_length: 1, max_length: 4),
        string(:printable, max_length: 6), max_length: 2)

  defp shape do
    one_of([
      constant(Conversation.text_shape()),
      constant(Conversation.note_shape()),
      constant(Conversation.approved_shape()),
      bind({id(), name(), input(), one_of([constant(nil), member_of(@kinds)])}, fn {i, n, inp,
                                                                                    err} ->
        constant(Conversation.call_shape(i, n, inp, err && String.to_atom(err)))
      end),
      bind({id(), name(), input()}, fn {i, n, inp} ->
        constant(Conversation.proposed_shape(i, n, inp))
      end),
      bind({id(), one_of([constant(nil), name()]), member_of(@kinds)}, fn {i, n, k} ->
        constant(Conversation.refused_shape(i, n, String.to_atom(k)))
      end)
    ])
  end

  defp transcript do
    bind(list_of(tuple({lines(), shape()}), max_length: 10), fn pairs ->
      chunks = Enum.map(pairs, &elem(&1, 0))
      shapes = Enum.map(pairs, &elem(&1, 1))
      # Now and then the shapes do not line up with the turns (a pre-shape blob).
      one_of([constant({chunks, shapes}), constant({chunks, Enum.drop(shapes, 1)})])
    end)
  end

  property "every built conversation meets the request-shape invariants the API enforces" do
    check all(
            {chunks, shapes} <- transcript(),
            native? <- boolean(),
            offered <- list_of(member_of(@names -- ["gone_tool"]), max_length: 2),
            goal <- string(:printable, min_length: 1, max_length: 10),
            String.trim(goal) != "",
            max_runs: 1_000
          ) do
      turns = Conversation.build(goal, chunks, shapes, native?: native?, tool_names: offered)
      roles = Enum.map(turns, & &1["role"])

      assert hd(roles) == "user"
      assert List.last(roles) == "user"
      assert roles |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)

      for turn <- turns, block <- turn["content"] do
        case block do
          %{"type" => "text", "text" => t} -> assert String.trim(t) != "", inspect(turns)
          %{"type" => "tool_result", "content" => c} -> assert String.trim(c) != ""
          %{"type" => "tool_call", "name" => n} -> assert native? and n in offered
        end
      end

      call_ids = for t <- turns, %{"type" => "tool_call", "id" => i} <- t["content"], do: i
      assert call_ids == Enum.uniq(call_ids), inspect(turns)

      turns
      |> Enum.with_index()
      |> Enum.each(fn {turn, i} ->
        calls = for %{"type" => "tool_call", "id" => id} <- turn["content"], do: id

        results =
          for %{"type" => "tool_result", "id" => id} <- turn["content"], do: id

        if calls != [] do
          next = Enum.at(turns, i + 1)
          assert next["role"] == "user"

          head_ids =
            next["content"]
            |> Enum.take_while(&(&1["type"] == "tool_result"))
            |> Enum.map(& &1["id"])

          assert head_ids == calls, inspect(turns)
        end

        if results != [] do
          # Answers only the calls of the message right before it, and only at its head.
          prev = Enum.at(turns, i - 1)
          assert i > 0 and prev["role"] == "assistant"
          assert results == for(%{"type" => "tool_call", "id" => id} <- prev["content"], do: id)

          assert Enum.take(turn["content"], length(results))
                 |> Enum.all?(&(&1["type"] == "tool_result"))
        end
      end)

      assert {:ok, _} = Chokepoint.seal(:complete, [goal], turns: turns)
    end
  end

  test "a transcript replaying a tool the deploy removed renders as text — native or not, tools offered or none" do
    chunks = [
      ["tool_call: gone_tool id=1", "status: shipped"],
      ["tool_error: invalid_args"],
      ["hello"]
    ]

    shapes = [
      Conversation.call_shape("toolu_01Gone", "gone_tool", %{"id" => "1"}, nil),
      Conversation.refused_shape("toolu_01Gone2", "gone_tool", :invalid_args),
      Conversation.text_shape()
    ]

    for offered <- [["fetch_record"], []] do
      turns = Conversation.build("g", chunks, shapes, native?: true, tool_names: offered)

      refute Enum.any?(turns, fn t ->
               Enum.any?(t["content"], &(&1["type"] in ["tool_call", "tool_result"]))
             end)

      assert turns == [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "g"}]
               },
               %{
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "tool_call: gone_tool id=1"}]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "status: shipped"},
                   %{
                     "type" => "text",
                     "text" =>
                       "tool_error: invalid_args\n" <>
                         "The arguments did not match the tool's input schema: send only the listed fields, " <>
                         "with every required field present and in the stated format."
                   }
                 ]
               },
               %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hello"}]},
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => Conversation.continue_text()}]
               }
             ]
    end

    # Positive control: the SAME transcript with the tool still offered replays natively.
    turns = Conversation.build("g", chunks, shapes, native?: true, tool_names: ["gone_tool"])
    ids = for t <- turns, %{"type" => "tool_call", "id" => i} <- t["content"], do: i
    assert ids == ["toolu_01Gone", "toolu_01Gone2"]
  end
end
