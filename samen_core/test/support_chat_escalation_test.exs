defmodule Samen.Support.ChatEscalationTest do
  @moduledoc """
  T60 / C6 — the chat offline-escalation capability's PURE + primitive-integration
  gates (the full DB path — ticket create, masking 3-proof, cross-org, stored-XSS,
  email fail-honest — is proven against real mounted Support resources in the demo
  host, `demo/test/support_chat_escalation_test.exs`; samen_core has no ticket
  fixture). Here:

    * the HONEST offline trigger (`Presence.evaluate/1`) — every reason + its
      discriminating control (agent online ⇒ serve; zero customer messages ⇒ serve);
    * the transcript projection (customer counting, last-customer time, stored-XSS
      sanitize, bounded subject);
    * the T41 escalation-primitive integration (`open_escalation_record/3`) against the
      REAL `AutomationFixture.Escalation` resource — opened once, idempotent-by-dedupe,
      and honestly `:skipped` when unwired (best-effort, never a bespoke path).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Support.Chat.{Config, Escalation, Presence, Transcript}
  alias SamenCore.Support.AutomationFixture.Escalation, as: EscalationRes
  alias SamenCore.TestRepo

  # ==========================================================================
  # Honest offline trigger — Presence.evaluate/1 (pure)
  # ==========================================================================

  describe "Presence.evaluate/1 — the honest offline/unserved decision" do
    test "zero customer messages never escalates (don't escalate our own agent/system chatter)" do
      assert Presence.evaluate(%{customer_messages: 0, agents_online: 0}) == :serve
    end

    test "no agent online with a customer waiting ⇒ escalate :no_agent_online" do
      assert Presence.evaluate(%{customer_messages: 1, agents_online: 0}) ==
               {:escalate, :no_agent_online}
    end

    test "an agent IS online ⇒ serve (the discriminating control)" do
      assert Presence.evaluate(%{customer_messages: 1, agents_online: 1}) == :serve
    end

    test "agent online but no answer within SLA ⇒ escalate :sla_elapsed" do
      now = ~U[2026-08-03 12:00:00Z]
      stale = DateTime.add(now, -600, :second)

      assert Presence.evaluate(%{
               customer_messages: 2,
               agents_online: 1,
               last_customer_at: stale,
               now: now,
               sla_seconds: 300
             }) == {:escalate, :sla_elapsed}
    end

    test "agent online, answered within SLA ⇒ serve (the SLA control)" do
      now = ~U[2026-08-03 12:00:00Z]
      recent = DateTime.add(now, -60, :second)

      assert Presence.evaluate(%{
               customer_messages: 2,
               agents_online: 1,
               last_customer_at: recent,
               now: now,
               sla_seconds: 300
             }) == :serve
    end

    test "explicit leave-a-message escalates regardless of presence" do
      assert Presence.evaluate(%{customer_messages: 1, agents_online: 5, leave_message?: true}) ==
               {:escalate, :leave_message}
    end

    test "presence is never fabricated: a missing agents_online is treated as zero (offline), not present" do
      # The honest default — absent presence data is NOT an excuse to pretend someone
      # is online. With a customer waiting and no presence signal, it escalates.
      assert Presence.evaluate(%{customer_messages: 1}) == {:escalate, :no_agent_online}
    end
  end

  # ==========================================================================
  # Transcript projection (pure) — counts, timing, stored-XSS, subject
  # ==========================================================================

  describe "Transcript" do
    test "counts only customer entries; agent/system entries never count" do
      entries = [
        %{sender_type: :customer, sender_label: "Visitor", body: "hi"},
        %{sender_type: :agent, sender_label: "Bot", body: "auto"},
        %{sender_type: :system, sender_label: "System", body: "queued"},
        %{sender_type: :customer, sender_label: "Visitor", body: "still here?"}
      ]

      assert Transcript.customer_count(entries) == 2
    end

    test "last_customer_at ignores agent/system times" do
      c1 = ~U[2026-08-03 12:00:00Z]
      a1 = ~U[2026-08-03 12:05:00Z]
      c2 = ~U[2026-08-03 12:02:00Z]

      entries = [
        %{sender_type: :customer, body: "a", at: c1},
        %{sender_type: :agent, body: "b", at: a1},
        %{sender_type: :customer, body: "c", at: c2}
      ]

      assert Transcript.last_customer_at(entries) == c2
    end

    test "render neutralizes stored-XSS in body AND label (T111 lineage)" do
      entries = [
        %{sender_type: :customer, sender_label: "<script>steal()</script>Mallory", body: "<img src=x onerror=\"alert(1)\">hello"}
      ]

      rendered = Transcript.render(entries)

      refute rendered =~ "<script"
      refute rendered =~ "<img"
      refute rendered =~ "onerror"
      assert rendered =~ "hello"
      assert rendered =~ "Mallory"
    end

    test "subject is derived from the first customer line, sanitized and bounded" do
      entries = [
        %{sender_type: :system, body: "greeting"},
        %{sender_type: :customer, body: "<script>x</script>My order #123 is late " <> String.duplicate("z", 300)}
      ]

      subject = Transcript.subject(entries)
      refute subject =~ "<script"
      assert subject =~ "My order"
      assert String.length(subject) <= 120
    end
  end

  # ==========================================================================
  # T41 escalation primitive integration — open_escalation_record/3
  # ==========================================================================

  describe "open_escalation_record/3 — the T41 primitive, best-effort" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

      prev = Application.get_env(:samen_core, Samen.Automation.Escalate)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, Samen.Automation.Escalate, prev),
          else: Application.delete_env(:samen_core, Samen.Automation.Escalate)
      end)

      :ok
    end

    defp cfg(opts) do
      Config.new(
        Keyword.merge(
          [
            org_id: Ash.UUID.generate(),
            repo: TestRepo,
            # Ticket resources are unused by open_escalation_record/3 (dummy atoms fine).
            ticket_resource: :ticket,
            conversation_resource: :conversation,
            message_resource: :message
          ],
          opts
        )
      )
    end

    test "unwired ⇒ :skipped (honest degrade, never aborts)" do
      assert Escalation.open_escalation_record(cfg([]), "thread-x", :no_agent_online) == :skipped
    end

    test "wired ⇒ opens a real Escalation row via the primitive; idempotent-by-dedupe" do
      config = cfg(escalation_module: EscalationRes, escalation_repo: TestRepo)
      ref = "thread-#{System.unique_integer([:positive])}"

      assert {:opened, :no_agent_online} =
               Escalation.open_escalation_record(config, ref, :no_agent_online)

      {:ok, rows} =
        EscalationRes
        |> Ash.Query.filter(org_id == ^config.org_id and kind == "chat_offline" and dedupe_key == ^ref)
        |> Ash.read(authorize?: false)

      assert length(rows) == 1

      # A second escalation for the SAME chat advances the SAME row — never a duplicate.
      assert {:opened, :sla_elapsed} =
               Escalation.open_escalation_record(config, ref, :sla_elapsed)

      {:ok, rows2} =
        EscalationRes
        |> Ash.Query.filter(org_id == ^config.org_id and kind == "chat_offline" and dedupe_key == ^ref)
        |> Ash.read(authorize?: false)

      assert length(rows2) == 1
    end
  end
end
