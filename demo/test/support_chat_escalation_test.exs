defmodule Demo.SupportChatEscalationTest do
  @moduledoc """
  DB-backed gate for the C6 chat offline-escalation capability (T60), against the DEMO
  host's REAL mounted Support + CRM resources — the first-client wiring (the framework
  `Samen.Support.Chat.Escalation` lives in samen_core; demo adopts it by handing a
  `Config` its own resource modules, ≈0 authored LOC, exactly like T59's inbound gate).
  Proves the security-critical properties on real Postgres:

    * (a) an offline/unserved chat escalates → a Ticket in the CORRECT org capturing
      the transcript (content via granted resolution)
    * (b) email fallback goes through `Samen.Delivery.Chokepoint` — fail-honest
      `{:error, :not_configured}` when unconfigured, a token-only capture when configured
    * (c) idempotent/bounded — a chat escalates AT MOST once (repeat ⇒ :already_escalated,
      no 2nd ticket, no 2nd email), sabotage-refutable
    * (d) org-scope — escalation never creates a ticket in another org (2-org)
    * (e) masking — the escalated ticket body renders masked per plane (MaskingCase 3-proof)
    * (f) stored-XSS — script/onerror in chat content is inert at rest in the ticket (T111)
  """
  use Demo.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Demo.SupportScope.{Ticket, Conversation, Message}
  alias Demo.CrmScope.Person
  alias Demo.Identity.Org
  alias Samen.Delivery.FakeProvider
  alias Samen.Support.Chat.{Config, Escalation}

  # Operator-without-grant vault stub (mirrors the T59 gate's DenyAll).
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # --- config / env sandboxing ----------------------------------------------

  @env_keys [:delivery_provider, :delivery_provider_overrides, :delivery_env]

  setup do
    prev = for k <- @env_keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}
    FakeProvider.reset()

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:samen_core, k, v), else: Application.delete_env(:samen_core, k)
      end
    end)

    :ok
  end

  defp configure_fake_provider(configured?) do
    Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: configured?}})
    Application.delete_env(:samen_core, :delivery_provider_overrides)
  end

  defp deconfigure_delivery do
    Application.delete_env(:samen_core, :delivery_provider)
    Application.delete_env(:samen_core, :delivery_provider_overrides)
  end

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org.id
  end

  defp cfg(org_id, opts) do
    Config.new(
      Keyword.merge(
        [
          org_id: org_id,
          repo: Demo.Repo,
          ticket_resource: Ticket,
          conversation_resource: Conversation,
          message_resource: Message,
          contact_resource: Person,
          our_domains: ["support.demo.test"],
          our_addresses: ["support@demo.test"],
          inbound_localpart: "support",
          delivery_env: :prod,
          escalation_template_id: "chat.escalation.ack"
        ],
        opts
      )
    )
  end

  defp transcript do
    [
      %{sender_type: :customer, sender_label: "Visitor", body: "SENTINEL-CHAT my invoice is wrong"},
      %{sender_type: :agent, sender_label: "Bot", body: "an agent will be with you"},
      %{sender_type: :customer, sender_label: "Visitor", body: "still waiting, hello?"}
    ]
  end

  defp ctx(thread_ref, opts \\ []) do
    %{
      thread_ref: thread_ref,
      reason: :no_agent_online,
      entries: Keyword.get(opts, :entries, transcript()),
      requester: Keyword.get(opts, :requester, %{
        address: "visitor@customer.test",
        display_name: "Vic Visitor",
        subscriber_id: Ash.UUID.generate()
      })
    }
  end

  defp ticket_count(org_id) do
    {:ok, n} = Ticket |> Ash.Query.filter(org_id == ^org_id) |> Ash.count(authorize?: false)
    n
  end

  defp load_msg(id), do: Ash.get!(Message, id, load: [:body], authorize?: false)

  defp delivered_to?(org_id, subscriber_id) do
    Enum.any?(FakeProvider.calls(), fn
      {:deliver, %{message: m}} -> m.org_id == org_id and m.to_subscriber_id == subscriber_id
      _ -> false
    end)
  end

  # ==========================================================================
  # (a) an offline chat escalates → Ticket in the correct org, transcript captured
  # ==========================================================================

  test "an unserved chat escalates: a ticket is created in the org, capturing the transcript" do
    configure_fake_provider(true)
    org = mk_org("acme-chat")

    assert {:ok, r} = Escalation.escalate(ctx("thread-a"), cfg(org, delivery_env: :test))
    assert r.disposition == :escalated
    assert r.ticket_id && r.conversation_id && r.message_id
    assert ticket_count(org) == 1

    # transcript content is present via granted (tenant-plane) resolution
    body = resolve_on_plane(load_msg(r.message_id), Message, :tenant, repo: Demo.Repo).body
    assert body =~ "SENTINEL-CHAT my invoice is wrong"
    assert body =~ "still waiting"

    {:ok, ticket} = Ash.get(Ticket, r.ticket_id, authorize?: false)
    assert ticket.subject =~ "SENTINEL-CHAT"
    assert ticket.external_id == "chat:thread-a"
  end

  # ==========================================================================
  # (b) email fallback via Delivery — fail-honest + configured capture
  # ==========================================================================

  test "email fallback is FAIL-HONEST when delivery is unconfigured (no fake ok)" do
    deconfigure_delivery()
    org = mk_org("failhonest-chat")

    assert {:ok, r} = Escalation.escalate(ctx("thread-fh"), cfg(org, delivery_env: :prod))
    # the handoff still creates the ticket, but the email honestly reports unconfigured
    assert r.disposition == :escalated
    assert r.email == {:error, :not_configured}
    refute delivered_to?(org, "anything")
  end

  test "email fallback goes through the chokepoint with a token-only envelope when configured" do
    configure_fake_provider(true)
    org = mk_org("configured-chat")
    sub = Ash.UUID.generate()

    c = ctx("thread-cfg", requester: %{address: "v@customer.test", display_name: "V", subscriber_id: sub})
    assert {:ok, r} = Escalation.escalate(c, cfg(org, delivery_env: :test))

    assert match?({:ok, _receipt}, r.email)
    # the envelope that reached the provider carries ONLY opaque ids — no chat plaintext.
    assert delivered_to?(org, sub)

    {:deliver, %{message: m}} = Enum.find(FakeProvider.calls(), &match?({:deliver, _}, &1))
    refute inspect(m) =~ "SENTINEL-CHAT"
    refute inspect(m) =~ "customer.test"
  end

  test "no verified requester subscriber ⇒ no email sent to nobody (honest :no_recipient)" do
    configure_fake_provider(true)
    org = mk_org("norecipient-chat")

    c = ctx("thread-nr", requester: %{address: "v@customer.test", display_name: "V", subscriber_id: nil})
    assert {:ok, r} = Escalation.escalate(c, cfg(org, delivery_env: :test))
    assert r.email == {:error, :no_recipient}
  end

  # ==========================================================================
  # (c) idempotent / bounded — a chat escalates AT MOST once
  # ==========================================================================

  test "repeated triggers escalate the chat AT MOST once (no N tickets, no N emails)" do
    configure_fake_provider(true)
    org = mk_org("idem-chat")
    sub = Ash.UUID.generate()
    c = ctx("thread-idem", requester: %{address: "v@customer.test", display_name: "V", subscriber_id: sub})

    assert {:ok, first} = Escalation.escalate(c, cfg(org, delivery_env: :test))
    assert first.disposition == :escalated
    assert match?({:ok, _}, first.email)

    calls_after_first = length(FakeProvider.calls())

    # fire the trigger 4 more times — the chat is already escalated.
    for _ <- 1..4 do
      assert {:ok, again} = Escalation.escalate(c, cfg(org, delivery_env: :test))
      assert again.disposition == :already_escalated
      assert again.ticket_id == first.ticket_id
      assert again.email == :skipped
    end

    # exactly ONE ticket, and NO further deliveries after the first escalation.
    assert ticket_count(org) == 1
    assert length(FakeProvider.calls()) == calls_after_first
  end

  test "CONCURRENT double-escalation of the SAME chat yields EXACTLY ONE ticket and ONE email" do
    # The regression the sequential test (c) missed: two escalations of the same chat
    # racing on real Postgres. Demo.DataCase already runs {:shared, self()} so both Tasks
    # use the owner's connection/transaction — the 2nd atomic ticket insert (same org_id +
    # external_id "chat:race-thread") collides on the partial-unique index. Exactly one
    # wins the create (and sends the ONE email); the loser re-reads the winner and returns
    # :already_escalated (email :skipped). SABOTAGE-REFUTABLE: drop the index and BOTH
    # inserts succeed -> 2 tickets + 2 escalated results (assertions below flip).
    configure_fake_provider(true)
    org = mk_org("race-chat")
    sub = Ash.UUID.generate()
    c = ctx("race-thread", requester: %{address: "v@customer.test", display_name: "V", subscriber_id: sub})

    parent = self()

    barrier = fn ->
      send(parent, {:ready, self()})
      receive do
        :go -> :ok
      end
    end

    race = fn ->
      barrier.()
      Escalation.escalate(c, cfg(org, delivery_env: :test))
    end

    t1 = Task.async(race)
    t2 = Task.async(race)

    # release both racers as close to simultaneously as we can
    assert_receive {:ready, p1}
    assert_receive {:ready, p2}
    send(p1, :go)
    send(p2, :go)

    {:ok, r1} = Task.await(t1)
    {:ok, r2} = Task.await(t2)

    # EXACTLY ONE ticket for the chat.
    assert ticket_count(org) == 1

    # one racer :escalated, the other :already_escalated (not two of either).
    assert Enum.sort([r1.disposition, r2.disposition]) == [:already_escalated, :escalated]

    # EXACTLY ONE email: the winner sent a real fallback; the loser sent NOTHING. (Email
    # results are read off each racer's own result — FakeProvider.calls is process-local
    # to each Task, so we assert on the returned outcomes, not the shared recorder.)
    emails = [r1.email, r2.email]
    assert Enum.count(emails, &match?({:ok, _}, &1)) == 1
    assert Enum.count(emails, &(&1 == :skipped)) == 1

    # both racers agree on the single winning ticket id.
    assert r1.ticket_id == r2.ticket_id
  end

  # ==========================================================================
  # (d) org-scope — escalation never creates/associates a ticket in another org
  # ==========================================================================

  test "escalation is org-scoped: a chat in org A never touches org B (2-org, refutable)" do
    configure_fake_provider(true)
    org_a = mk_org("org-a")
    org_b = mk_org("org-b")

    # org B already escalated a chat with the SAME thread_ref string.
    assert {:ok, b} = Escalation.escalate(ctx("shared-ref"), cfg(org_b, delivery_env: :test))
    assert b.disposition == :escalated
    assert ticket_count(org_b) == 1

    # org A escalates a chat that happens to carry the identical thread_ref — it must
    # NOT see org B's escalation (the dedupe key is org-scoped) → a NEW ticket in org A.
    assert {:ok, a} = Escalation.escalate(ctx("shared-ref"), cfg(org_a, delivery_env: :test))
    assert a.disposition == :escalated
    assert a.ticket_id != b.ticket_id
    assert ticket_count(org_a) == 1
    assert ticket_count(org_b) == 1

    # the org-A ticket belongs to org A (never org B): it is readable under org A's
    # scope filter and NOT under org B's.
    {:ok, in_a} = Ticket |> Ash.Query.filter(id == ^a.ticket_id and org_id == ^org_a) |> Ash.read(authorize?: false)
    {:ok, in_b} = Ticket |> Ash.Query.filter(id == ^a.ticket_id and org_id == ^org_b) |> Ash.read(authorize?: false)
    assert length(in_a) == 1
    assert in_b == []

    # POSITIVE CONTROL: re-escalating within org A is idempotent (same ticket).
    assert {:ok, a2} = Escalation.escalate(ctx("shared-ref"), cfg(org_a, delivery_env: :test))
    assert a2.disposition == :already_escalated
    assert a2.ticket_id == a.ticket_id
  end

  # ==========================================================================
  # (e) masking — the escalated ticket body masks per plane (3-proof)
  # ==========================================================================

  test "escalated ticket body: tenant clear ∧ operator masked ∧ vt_ at rest (3-proof)" do
    configure_fake_provider(true)
    org = mk_org("mask-chat")

    assert {:ok, r} = Escalation.escalate(ctx("thread-mask"), cfg(org, delivery_env: :test))
    msg = load_msg(r.message_id)

    # GREEN — tenant resolves clear.
    tenant = resolve_on_plane(msg, Message, :tenant, repo: Demo.Repo).body
    assert_plane_clear!(tenant, tenant)
    assert tenant =~ "SENTINEL-CHAT"

    # RED — operator-without-grant masks.
    operator = resolve_on_plane(msg, Message, :operator, repo: Demo.Repo, grant: DenyAll).body
    assert_plane_masked!(operator, "SENTINEL-CHAT")

    # SABOTAGE twin — the tenant render DOES carry the sentinel (the refute is refutable).
    assert_leak_detected!(to_string(tenant), "SENTINEL-CHAT")

    # at rest: a vt_ token, never the plaintext.
    %{rows: [[raw]]} =
      Demo.Repo.query!("SELECT pii_smg_body FROM smg_message WHERE smg_id = $1", [Ecto.UUID.dump!(r.message_id)])

    assert String.starts_with?(raw, "vt_")
    refute raw =~ "SENTINEL-CHAT"
  end

  # ==========================================================================
  # (f) stored-XSS — script/onerror in chat content is inert at rest (T111)
  # ==========================================================================

  test "script/onerror in chat messages is inert at rest in the escalated ticket" do
    configure_fake_provider(true)
    org = mk_org("xss-chat")

    xss_entries = [
      %{sender_type: :customer, sender_label: "Mallory", body: "<img src=x onerror=\"alert(1)\">refund now"},
      %{sender_type: :customer, sender_label: "Mallory", body: "<script>steal()</script>please"}
    ]

    assert {:ok, r} =
             Escalation.escalate(ctx("thread-xss", entries: xss_entries), cfg(org, delivery_env: :test))

    # ticket.subject stored sanitized (raw SQL — no live tag at the at-rest column).
    %{rows: [[stored_subject]]} =
      Demo.Repo.query!("SELECT stk_subject FROM stk_ticket WHERE stk_id = $1", [Ecto.UUID.dump!(r.ticket_id)])

    refute stored_subject =~ "<script"
    refute stored_subject =~ "<img"

    # message body, revealed on the tenant plane, carries no live tag/handler.
    body = resolve_on_plane(load_msg(r.message_id), Message, :tenant, repo: Demo.Repo).body
    refute body =~ "<script"
    refute body =~ "<img"
    refute body =~ "onerror"
    assert body =~ "refund now"

    # SABOTAGE twin — the raw input DID carry the live handler.
    assert Enum.at(xss_entries, 0).body =~ "onerror"
  end
end
