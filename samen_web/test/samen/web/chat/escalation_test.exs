defmodule Samen.Web.Chat.EscalationTest do
  @moduledoc """
  T60 / C6 — the crossplane-chat adopter of the offline-escalation capability. The
  framework capability + its full DB gate (ticket create, masking 3-proof, cross-org,
  email fail-honest) live in samen_core / the demo host; this proves the thin chat-native
  WIRING: honest support-agent presence derived from a real presence roster, and the
  `ChatMessage` → transcript-entry mapping (operator = agent, tenant = customer), feeding
  the honest `Presence.evaluate/1` trigger.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Chat.Escalation, as: ChatEscalation

  # A presence roster as `Phoenix.Presence.list/1` returns it (meta shape from
  # `Samen.Web.Chat.Presence.meta/2` — non-PII: party + handle only).
  defp roster(parties) do
    parties
    |> Enum.with_index()
    |> Map.new(fn {party, i} ->
      {"p#{i}", %{metas: [%{party: party, handle: "h#{i}", typing: false, online_at: 0}]}}
    end)
  end

  describe "agents_online/1 — honest support-agent presence" do
    test "counts only OPERATOR-party members present" do
      assert ChatEscalation.agents_online(roster([:operator, :tenant, :tenant])) == 1
      assert ChatEscalation.agents_online(roster([:operator, :operator])) == 2
    end

    test "a customer (tenant) alone in the room is NOT an agent online" do
      assert ChatEscalation.agents_online(roster([:tenant])) == 0
    end

    test "an empty roster is zero agents (presence is never fabricated)" do
      assert ChatEscalation.agents_online(%{}) == 0
      assert ChatEscalation.agents_online([]) == 0
    end
  end

  describe "transcript_entry/3 — ChatMessage → core transcript entry" do
    test "operator-party maps to :agent; tenant-party maps to :customer" do
      at = ~U[2026-08-03 12:00:00Z]
      op = ChatEscalation.transcript_entry(%{sender_party: :operator, inserted_at: at}, "how can I help?", "Agent A")
      cust = ChatEscalation.transcript_entry(%{sender_party: :tenant, inserted_at: at}, "my order is late", "Visitor")

      assert op.sender_type == :agent
      assert op.sender_label == "Agent A"
      assert cust.sender_type == :customer
      assert cust.body == "my order is late"
      assert cust.at == at
    end
  end

  describe "build_signal/3 + evaluate/1 — the honest trigger end to end" do
    test "a customer waiting with no operator present ⇒ escalate :no_agent_online" do
      entries = [
        ChatEscalation.transcript_entry(%{sender_party: :tenant, inserted_at: DateTime.utc_now()}, "help", "Visitor")
      ]

      signal = ChatEscalation.build_signal(entries, roster([:tenant]))
      assert ChatEscalation.evaluate(signal) == {:escalate, :no_agent_online}
    end

    test "the same chat with an operator present ⇒ serve (the discriminating control)" do
      entries = [
        ChatEscalation.transcript_entry(%{sender_party: :tenant, inserted_at: DateTime.utc_now()}, "help", "Visitor")
      ]

      signal = ChatEscalation.build_signal(entries, roster([:tenant, :operator]))
      assert ChatEscalation.evaluate(signal) == :serve
    end

    test "an operator-only room (no customer message) never escalates" do
      entries = [
        ChatEscalation.transcript_entry(%{sender_party: :operator, inserted_at: DateTime.utc_now()}, "anyone there?", "Agent")
      ]

      signal = ChatEscalation.build_signal(entries, roster([:operator]))
      assert ChatEscalation.evaluate(signal) == :serve
    end
  end
end
