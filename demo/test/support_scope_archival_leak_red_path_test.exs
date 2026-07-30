defmodule Demo.SupportScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the Support scope (ADR-040 §5.9, T37f): `ticket`,
  `agent`, `sla`, `macro` flip `archivable true`
  (samen_core/lib/samen/scopes/support/blueprint.ex) — `ticket` is also the
  roster's cascade PARENT of `ticket ▸cascade conversation ▸cascade message`
  (§5.4, the ADR's own canonical worked example of a composition cascade).
  `csat` stays excluded (L — ledger) and is left untouched.

  `Conversation`/`Message` are ALSO `archivable true` (substrate only — the
  cascade needs something to set/match/restore), but per the roster's syntax
  (`ticket ▸cascade conversation ▸cascade message` has NO internal commas — the
  same shape as chat's `thread ▸cascade participant ▸cascade message`, T37e,
  unlike CMS's comma-separated `page ▸cascade block`, T37b, which explicitly
  permits independent block archiving) both carry an explicit
  `policy action([:archive, :restore]) do forbid_if(always()) end` — proven
  directly below (§5.4-policy). The ONLY path that ever archives/restores a
  conversation or message is the ticket's cascade
  (`Samen.Scopes.Support.CascadeArchive`/`CascadeRestore`), which runs
  `authorize?: false`.

  Unlike CMS's `Block` (which permits independent archiving, so a genuinely
  independent same-parent, different-instant sibling is constructible under the
  SAME live page) and unlike chat's `Participant`/`Message` (single-hop: FKed
  DIRECTLY to their cascade parent), support's cascade is TWO-HOP — `message` has
  no `ticket_id` column at all, only `conversation_id` — and BOTH children are
  cascade-locked, so there is no way to construct a conversation/message
  archived independently, at a different instant, under a still-live SAME
  ticket. The "independently archived, stays archived" contract (§5.4) is
  therefore proven via a DIFFERENT ticket's cascade-archived conversation/
  message (structurally, never reachable by another ticket's restore query,
  which filters by BOTH `ticket_id`/`conversation_id` scope AND `archived_at`
  instant — see the two describe blocks below, including the true same-wall-
  clock-second collision case).

  §5.3: no `unique_index` exists on any of `stk_ticket` / `scv_conversation` /
  `smg_message` / `sag_agent` / `ssl_sla` / `smc_macro` today (confirmed by
  inspecting `20260706050000_add_support_scope` — zero `unique_index` calls) —
  nothing to convert to partial form, and `:restore_conflict` is therefore not
  constructible here; T36's generic `{:error, :restore_conflict}` mapping is
  unmodified.

  §5.5's standing duty — an archived record must not leak via relationship load
  or aggregate — is exercised on FOUR distinct belongs_to consumers:
  `Csat.ticket`, `Message.agent`, `Ticket.sla` (all pre-existing), and the new
  `Ticket.conversations`/`Conversation.messages` `has_many`s this task added
  (both a relationship-load and an `:exists` aggregate proof, the latter
  necessarily coupled to the ticket's OWN cascade-archive per the note above).

  INV-1 — the masking-on-archived proof — runs on this scope's TWO 🔒 fields:
  `Message.body` (the handoff's named target, archived directly via
  `authorize?: false` — same posture chat's own Message/Participant masking
  tests use, isolating the archival mechanic from the cascade mechanic already
  proven separately) and `Agent.full_name` (a directly, independently archivable
  resource — no cascade).
  """
  use Demo.DataCase, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Demo.SupportScope.{Ticket, Conversation, Message, Agent, Sla, Macro, Csat}

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_sla(org_id, name \\ "sla") do
    {:ok, sla} =
      Sla
      |> Ash.Changeset.for_create(:create, %{
        name: "#{name}-#{:rand.uniform(999_999)}",
        label: "SLA",
        first_response_minutes: 60,
        resolve_minutes: 480,
        priority: :normal,
        enabled: true,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    sla
  end

  defp mk_ticket(org_id, subject \\ "Ticket", sla_id \\ nil) do
    attrs =
      %{
        subject: "#{subject}-#{:rand.uniform(999_999)}",
        status: :open,
        priority: :normal,
        org_id: org_id
      }
      |> then(fn a -> if sla_id, do: Map.put(a, :sla_id, sla_id), else: a end)

    {:ok, ticket} =
      Ticket
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(authorize?: false)

    ticket
  end

  defp mk_conversation(org_id, ticket_id, subject \\ "Conversation") do
    {:ok, conversation} =
      Conversation
      |> Ash.Changeset.for_create(:create, %{
        channel: :email,
        status: :open,
        subject: "#{subject}-#{:rand.uniform(999_999)}",
        org_id: org_id,
        ticket_id: ticket_id
      })
      |> Ash.create(authorize?: false)

    conversation
  end

  defp mk_message(org_id, conversation_id, body \\ nil, agent_id \\ nil) do
    attrs =
      %{
        body: body || "message body #{:rand.uniform(999_999)}",
        sender_type: :customer,
        message_type: :reply,
        org_id: org_id,
        conversation_id: conversation_id
      }
      |> then(fn a -> if agent_id, do: Map.put(a, :agent_id, agent_id), else: a end)

    {:ok, message} =
      Message
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(authorize?: false)

    message
  end

  defp mk_agent(org_id, opts \\ []) do
    first = Keyword.get(opts, :first, "Dana")
    last = Keyword.get(opts, :last, "Operator-#{:rand.uniform(999_999)}")

    {:ok, agent} =
      Agent
      |> Ash.Changeset.for_create(:create, %{
        handle: "agent-#{:rand.uniform(999_999)}",
        full_name: %Samen.Type.FullName{first: first, last: last},
        email: "agent-#{:rand.uniform(999_999)}@support.example",
        status: :active,
        role: :agent,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    agent
  end

  defp mk_macro(org_id) do
    {:ok, macro} =
      Macro
      |> Ash.Changeset.for_create(:create, %{
        name: "macro-#{:rand.uniform(999_999)}",
        description: "Standard acknowledgement",
        body_template: "Thank you for contacting support.",
        tags: ["ack"],
        enabled: true,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    macro
  end

  defp mk_csat(org_id, ticket_id, agent_id \\ nil) do
    attrs =
      %{
        score: 5,
        comments: "Great support experience!",
        channel: :email,
        responded_at: DateTime.utc_now(),
        org_id: org_id,
        ticket_id: ticket_id
      }
      |> then(fn a -> if agent_id, do: Map.put(a, :agent_id, agent_id), else: a end)

    {:ok, csat} =
      Csat
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(authorize?: false)

    csat
  end

  defp live_ids(resource, org_id) do
    resource
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_ids(resource, org_id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_record(resource, id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # T124-adjacent same-wall-clock-second regression helper, TWO-TICKET variant
  # (the single-parent CMS/T37b and chat/T37e precedents force a collision
  # between a page/thread and its OWN independent sibling under the SAME
  # parent; support's conversation/message cascade-lock makes that
  # construction impossible — see moduledoc — so this forces the collision
  # between TWO DIFFERENT tickets' own cascades instead, which is the
  # meaningful edge for this resource shape: it proves the restore-match query
  # scopes by ticket_id/conversation_id, NOT by archived_at equality alone).
  @same_second_max_attempts 40

  defp archive_two_tickets_same_second!(attempt \\ 1) do
    org = mk_org()
    ticket_a = mk_ticket(org, "Same-Second-A")
    conv_a = mk_conversation(org, ticket_a.id)
    msg_a = mk_message(org, conv_a.id)

    ticket_b = mk_ticket(org, "Same-Second-B")
    conv_b = mk_conversation(org, ticket_b.id)
    msg_b = mk_message(org, conv_b.id)

    {:ok, archived_b} = Samen.Archival.archive(ticket_b, authorize?: false)
    {:ok, archived_a} = Samen.Archival.archive(ticket_a, authorize?: false)

    if DateTime.truncate(archived_b.archived_at, :second) ==
         DateTime.truncate(archived_a.archived_at, :second) do
      %{
        org: org,
        ticket_a: archived_a,
        conv_a: conv_a,
        msg_a: msg_a,
        ticket_b: archived_b,
        conv_b: conv_b,
        msg_b: msg_b
      }
    else
      if attempt >= @same_second_max_attempts do
        flunk(
          "could not reproduce a same-wall-clock-second archive collision between two " <>
            "tickets after #{@same_second_max_attempts} attempts — environment too slow " <>
            "for this regression test to exercise the edge"
        )
      else
        archive_two_tickets_same_second!(attempt + 1)
      end
    end
  end

  # ── introspection: the adopt-me convention landed on the roster row ────────

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "ticket/conversation/message/agent/sla/macro report true; csat reports false" do
      assert Samen.Info.archivable?(Ticket)
      assert Samen.Info.archivable?(Conversation)
      assert Samen.Info.archivable?(Message)
      assert Samen.Info.archivable?(Agent)
      assert Samen.Info.archivable?(Sla)
      assert Samen.Info.archivable?(Macro)
      refute Samen.Info.archivable?(Csat)
    end
  end

  # ── c1: archive/restore round trip — the independently-archivable resources ─

  describe "c1 — archive removes from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
    test "Ticket" do
      org = mk_org()
      ticket = mk_ticket(org)

      assert MapSet.member?(live_ids(Ticket, org), ticket.id)

      {:ok, _} = Samen.Archival.archive(ticket, authorize?: false)

      refute MapSet.member?(live_ids(Ticket, org), ticket.id)
      assert MapSet.member?(archived_ids(Ticket, org), ticket.id)

      {:ok, _} = Samen.Archival.restore(archived_record(Ticket, ticket.id), authorize?: false)
      assert MapSet.member?(live_ids(Ticket, org), ticket.id)
      refute MapSet.member?(archived_ids(Ticket, org), ticket.id)
    end

    test "Agent" do
      org = mk_org()
      agent = mk_agent(org)

      assert MapSet.member?(live_ids(Agent, org), agent.id)

      {:ok, _} = Samen.Archival.archive(agent, authorize?: false)

      refute MapSet.member?(live_ids(Agent, org), agent.id)
      assert MapSet.member?(archived_ids(Agent, org), agent.id)

      {:ok, _} = Samen.Archival.restore(archived_record(Agent, agent.id), authorize?: false)
      assert MapSet.member?(live_ids(Agent, org), agent.id)
    end

    test "Sla" do
      org = mk_org()
      sla = mk_sla(org)

      assert MapSet.member?(live_ids(Sla, org), sla.id)

      {:ok, _} = Samen.Archival.archive(sla, authorize?: false)

      refute MapSet.member?(live_ids(Sla, org), sla.id)
      assert MapSet.member?(archived_ids(Sla, org), sla.id)

      {:ok, _} = Samen.Archival.restore(archived_record(Sla, sla.id), authorize?: false)
      assert MapSet.member?(live_ids(Sla, org), sla.id)
    end

    test "Macro" do
      org = mk_org()
      macro = mk_macro(org)

      assert MapSet.member?(live_ids(Macro, org), macro.id)

      {:ok, _} = Samen.Archival.archive(macro, authorize?: false)

      refute MapSet.member?(live_ids(Macro, org), macro.id)
      assert MapSet.member?(archived_ids(Macro, org), macro.id)

      {:ok, _} = Samen.Archival.restore(archived_record(Macro, macro.id), authorize?: false)
      assert MapSet.member?(live_ids(Macro, org), macro.id)
    end
  end

  # ── §5.4-policy: conversation/message have NO independent archive for a real actor ─

  describe "§5.4 ¶ — an actor-driven :archive/:restore on Conversation/Message is refused" do
    test "a real org-scoped member actor cannot call :archive on a Conversation directly" do
      org = mk_org()
      ticket = mk_ticket(org)
      conversation = mk_conversation(org, ticket.id)
      actor = %{org_id: org, role: :member}

      result =
        conversation
        |> Ash.Changeset.for_destroy(:archive, %{}, actor: actor)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "a real org-scoped member actor cannot call :archive on a Message directly" do
      org = mk_org()
      ticket = mk_ticket(org)
      conversation = mk_conversation(org, ticket.id)
      message = mk_message(org, conversation.id)
      actor = %{org_id: org, role: :member}

      result =
        message
        |> Ash.Changeset.for_destroy(:archive, %{}, actor: actor)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "the SAME actor CAN archive the Ticket itself (CONTROL — proves the forbid above is Conversation/Message-specific, not a blanket deny)" do
      org = mk_org()
      ticket = mk_ticket(org)
      actor = %{org_id: org, role: :member}

      assert {:ok, _} = Samen.Archival.archive(ticket, actor: actor)
    end
  end

  # ── §5.4 cascade: ticket ▸cascade {conversation, message} — same-instant archive ─

  describe "§5.4 — archiving a Ticket cascades to archive its Conversations AND Messages at the same instant" do
    test "both conversations and both messages land on the EXACT same archived_at as the ticket (RED: hidden; CONTROL: unrelated ticket untouched)" do
      org = mk_org()
      ticket = mk_ticket(org, "Cascade Archive")
      other_ticket = mk_ticket(org, "Untouched")

      conv1 = mk_conversation(org, ticket.id)
      conv2 = mk_conversation(org, ticket.id)
      msg1 = mk_message(org, conv1.id)
      msg2 = mk_message(org, conv2.id)

      other_conv = mk_conversation(org, other_ticket.id)
      other_msg = mk_message(org, other_conv.id)

      {:ok, archived_ticket} = Samen.Archival.archive(ticket, authorize?: false)

      # RED: both cascaded conversations and messages vanish from default reads.
      refute MapSet.member?(live_ids(Conversation, org), conv1.id)
      refute MapSet.member?(live_ids(Conversation, org), conv2.id)
      refute MapSet.member?(live_ids(Message, org), msg1.id)
      refute MapSet.member?(live_ids(Message, org), msg2.id)
      # CONTROL: an unrelated ticket's conversation/message are untouched.
      assert MapSet.member?(live_ids(Conversation, org), other_conv.id)
      assert MapSet.member?(live_ids(Message, org), other_msg.id)

      assert archived_record(Conversation, conv1.id).archived_at == archived_ticket.archived_at
      assert archived_record(Conversation, conv2.id).archived_at == archived_ticket.archived_at
      assert archived_record(Message, msg1.id).archived_at == archived_ticket.archived_at
      assert archived_record(Message, msg2.id).archived_at == archived_ticket.archived_at
    end
  end

  # ── §5.4 cascade: restore restores exactly THIS ticket's cascade set ───────

  describe "§5.4 — restoring a Ticket restores exactly its own cascade-archived Conversations/Messages" do
    test "a DIFFERENT ticket's independently cascade-archived conversation/message stays archived when this ticket restores (RED); this ticket's own cascade set returns (CONTROL)" do
      org = mk_org()
      ticket_a = mk_ticket(org, "Restore Match A")
      conv_a = mk_conversation(org, ticket_a.id)
      msg_a = mk_message(org, conv_a.id)

      ticket_b = mk_ticket(org, "Restore Match B (independent)")
      conv_b = mk_conversation(org, ticket_b.id)
      msg_b = mk_message(org, conv_b.id)

      # Archive ticket_b FIRST, at its own instant.
      {:ok, archived_ticket_b} = Samen.Archival.archive(ticket_b, authorize?: false)

      # Force a distinct instant with a >1s sleep — belt-and-suspenders on top of
      # the T124 microsecond fix (see the no-sleep same-second test below for the
      # direct edge reproduction).
      Process.sleep(1_100)

      {:ok, archived_ticket_a} = Samen.Archival.archive(ticket_a, authorize?: false)

      # Sanity: the two cascades really did land at different instants.
      assert archived_record(Conversation, conv_a.id).archived_at == archived_ticket_a.archived_at
      assert archived_record(Conversation, conv_b.id).archived_at == archived_ticket_b.archived_at
      refute archived_record(Conversation, conv_a.id).archived_at ==
               archived_record(Conversation, conv_b.id).archived_at

      {:ok, _restored_ticket_a} = Samen.Archival.restore(archived_ticket_a, authorize?: false)

      # CONTROL: ticket_a's own cascade set came back.
      assert MapSet.member?(live_ids(Conversation, org), conv_a.id)
      assert MapSet.member?(live_ids(Message, org), msg_a.id)

      # RED: ticket_b's cascade-archived members — a DIFFERENT ticket's own
      # cascade — are untouched by ticket_a's restore (ADR-040 §5.4: "a child
      # independently archived [under a different parent] stays archived").
      refute MapSet.member?(live_ids(Conversation, org), conv_b.id)
      refute MapSet.member?(live_ids(Message, org), msg_b.id)
      assert MapSet.member?(archived_ids(Conversation, org), conv_b.id)
      assert MapSet.member?(archived_ids(Message, org), msg_b.id)
    end
  end

  # ── §5.4 cascade: same wall-clock second, two-ticket collision (T124-adjacent) ─

  describe "§5.4 — same wall-clock second, two tickets (T124-adjacent)" do
    test "ticket_a's restore does not mis-restore ticket_b's cascade-archived conversation/message even when both cascades land in the same wall-clock second" do
      %{
        ticket_a: archived_ticket_a,
        conv_a: conv_a,
        msg_a: msg_a,
        ticket_b: archived_ticket_b,
        conv_b: conv_b,
        msg_b: msg_b,
        org: org
      } = archive_two_tickets_same_second!()

      # Sanity: we really did land in the same wall-clock second.
      assert DateTime.truncate(archived_ticket_a.archived_at, :second) ==
               DateTime.truncate(archived_ticket_b.archived_at, :second)

      # Under the pre-T124 substrate (`archived_at` silently second-granular
      # regardless of column type), the two tickets' persisted instants — and
      # therefore their cascaded conversations'/messages' instants — could
      # collide byte-exact. Even so, this restore-match query ALSO scopes by
      # `ticket_id`/`conversation_id` (see `Samen.Scopes.Support.CascadeRestore`
      # moduledoc), so ticket_b's members must stay archived regardless of any
      # timestamp collision — a defense-in-depth this two-hop, two-ticket shape
      # has that the single-parent CMS/chat precedents cannot exercise the same
      # way (their "independent" sibling always shares the archiving parent).
      {:ok, _restored_ticket_a} = Samen.Archival.restore(archived_ticket_a, authorize?: false)

      # CONTROL: ticket_a's own cascade set came back.
      assert MapSet.member?(live_ids(Conversation, org), conv_a.id)
      assert MapSet.member?(live_ids(Message, org), msg_a.id)

      # RED: ticket_b's cascade-archived members are NOT swept up by ticket_a's
      # restore, even though both tickets' archive instants land in the same
      # wall-clock second.
      refute MapSet.member?(live_ids(Conversation, org), conv_b.id)
      refute MapSet.member?(live_ids(Message, org), msg_b.id)
      assert MapSet.member?(archived_ids(Conversation, org), conv_b.id)
      assert MapSet.member?(archived_ids(Message, org), msg_b.id)
    end
  end

  # ── §5.5 leak duty: relationship load — Csat.ticket ─────────────────────────

  describe "§5.5 — an archived Ticket does not leak via Csat.ticket relationship load" do
    test "Csat.ticket resolves to nil for an archived ticket (RED); a live ticket surfaces (CONTROL)" do
      org = mk_org()

      archived_ticket = mk_ticket(org, "Archived")
      live_ticket = mk_ticket(org, "Live")

      csat_on_archived = mk_csat(org, archived_ticket.id)
      csat_on_live = mk_csat(org, live_ticket.id)

      {:ok, _} = Samen.Archival.archive(archived_ticket, authorize?: false)

      loaded_on_archived = Ash.load!(csat_on_archived, :ticket, authorize?: false)
      assert loaded_on_archived.ticket == nil

      loaded_on_live = Ash.load!(csat_on_live, :ticket, authorize?: false)
      assert %Ticket{id: live_id} = loaded_on_live.ticket
      assert live_id == live_ticket.id
    end
  end

  # ── §5.5 leak duty: relationship load — Message.agent ───────────────────────

  describe "§5.5 — an archived Agent does not leak via Message.agent relationship load" do
    test "Message.agent resolves to nil for an archived agent (RED); a live agent surfaces (CONTROL)" do
      org = mk_org()
      ticket = mk_ticket(org)
      conversation = mk_conversation(org, ticket.id)

      archived_agent = mk_agent(org, first: "Archived")
      live_agent = mk_agent(org, first: "Live")

      msg_on_archived = mk_message(org, conversation.id, nil, archived_agent.id)
      msg_on_live = mk_message(org, conversation.id, nil, live_agent.id)

      {:ok, _} = Samen.Archival.archive(archived_agent, authorize?: false)

      loaded_on_archived = Ash.load!(msg_on_archived, :agent, authorize?: false)
      assert loaded_on_archived.agent == nil

      loaded_on_live = Ash.load!(msg_on_live, :agent, authorize?: false)
      assert %Agent{id: live_id} = loaded_on_live.agent
      assert live_id == live_agent.id

      # No unintended cascade: the message ITSELF stays live — only its `.agent`
      # relationship LOAD is filtered.
      assert MapSet.member?(live_ids(Message, org), msg_on_archived.id)
    end
  end

  # ── §5.5 leak duty: relationship load — Ticket.sla ──────────────────────────

  describe "§5.5 — an archived Sla does not leak via Ticket.sla relationship load" do
    test "Ticket.sla resolves to nil for an archived sla (RED); a live sla surfaces (CONTROL)" do
      org = mk_org()

      archived_sla = mk_sla(org, "archived-sla")
      live_sla = mk_sla(org, "live-sla")

      ticket_on_archived = mk_ticket(org, "T-archived-sla", archived_sla.id)
      ticket_on_live = mk_ticket(org, "T-live-sla", live_sla.id)

      {:ok, _} = Samen.Archival.archive(archived_sla, authorize?: false)

      loaded_on_archived = Ash.load!(ticket_on_archived, :sla, authorize?: false)
      assert loaded_on_archived.sla == nil

      loaded_on_live = Ash.load!(ticket_on_live, :sla, authorize?: false)
      assert %Sla{id: live_id} = loaded_on_live.sla
      assert live_id == live_sla.id
    end
  end

  # ── §5.5 leak duty: relationship load — Ticket.conversations (cascade-coupled) ─

  describe "§5.5 — an archived Ticket's conversations do not leak via relationship load" do
    test "Ticket.conversations resolves empty for an archived (cascade-archived) ticket (RED); a live ticket's conversations surface (CONTROL)" do
      org = mk_org()
      archived_ticket = mk_ticket(org, "Archived-Rel")
      live_ticket = mk_ticket(org, "Live-Rel")

      archived_conv = mk_conversation(org, archived_ticket.id)
      _archived_msg = mk_message(org, archived_conv.id)

      live_conv = mk_conversation(org, live_ticket.id)
      _live_msg = mk_message(org, live_conv.id)

      {:ok, _} = Samen.Archival.archive(archived_ticket, authorize?: false)

      loaded_archived =
        Ticket
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^archived_ticket.id)
        |> Ash.Query.load(:conversations)
        |> Ash.read_one!(authorize?: false)

      assert loaded_archived.conversations == []

      # CONTROL (anti-tautology): the identical relationship load on a LIVE
      # ticket surfaces its conversation — proves the empty list above is the
      # archival filter firing (both the ticket AND its cascaded conversation
      # are archived — either alone would already empty this via
      # ExcludeArchived on the child side), not a structurally broken
      # relationship.
      loaded_live =
        Ticket |> Ash.get!(live_ticket.id, authorize?: false, load: [:conversations])

      assert [%Conversation{id: cid}] = loaded_live.conversations
      assert cid == live_conv.id
    end
  end

  # ── §5.5 leak duty: aggregate — Ticket :exists on :conversations ───────────

  describe "§5.5 — an archived Ticket's conversations do not leak via an :exists aggregate" do
    test "the :exists aggregate over Ticket.conversations is false for a cascade-archived ticket (RED); true for a live one (CONTROL)" do
      org = mk_org()
      archived_ticket = mk_ticket(org, "Archived-Agg")
      live_ticket = mk_ticket(org, "Live-Agg")

      archived_conv = mk_conversation(org, archived_ticket.id)
      mk_message(org, archived_conv.id)

      live_conv = mk_conversation(org, live_ticket.id)
      mk_message(org, live_conv.id)

      {:ok, _} = Samen.Archival.archive(archived_ticket, authorize?: false)

      {:ok, archived_result} =
        Ticket
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^archived_ticket.id)
        |> Ash.Query.aggregate(:conversations_live?, :exists, :conversations)
        |> Ash.read_one(authorize?: false)

      refute archived_result.aggregates.conversations_live?

      # CONTROL (anti-tautology): the identical aggregate over a live ticket
      # reports true — proves `false` above is the archival filter firing, not
      # the aggregate being vacuously false.
      {:ok, live_result} =
        Ticket
        |> Ash.Query.filter(id == ^live_ticket.id)
        |> Ash.Query.aggregate(:conversations_live?, :exists, :conversations)
        |> Ash.read_one(authorize?: false)

      assert live_result.aggregates.conversations_live?
    end
  end

  # ── §5.4: no cascade default — Sla/Macro archival is standalone ────────────

  describe "§5.4 — no cascade declared for Sla/Macro (default no-cascade)" do
    test "archiving an Sla does not touch an unrelated live Ticket pointing at it" do
      org = mk_org()
      sla = mk_sla(org)
      ticket = mk_ticket(org, "No Cascade", sla.id)

      {:ok, _} = Samen.Archival.archive(sla, authorize?: false)

      # The ticket itself stays live (its own default read still surfaces it) —
      # only its `.sla` RELATIONSHIP LOAD is filtered (proven above).
      assert MapSet.member?(live_ids(Ticket, org), ticket.id)
    end
  end

  # ── INV-1: masking holds on an archived vaulted Message, restore never leaks ──

  describe "INV-1 — an archived Message still masks body per plane, restore never leaks" do
    test "archived Message keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      ticket = mk_ticket(org)
      conversation = mk_conversation(org, ticket.id)
      body = "SUPPORT-BODY-ARCHIVED-SENTINEL confidential account details"
      message = mk_message(org, conversation.id, body)

      {:ok, _} = Samen.Archival.archive(message, authorize?: false)

      archived =
        Message
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:body])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == message.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived —
      # trash, not erasure (§5.1).
      %{rows: [[stored]]} =
        Repo.query!("SELECT pii_smg_body FROM smg_message WHERE smg_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves to %Masked{} —
      # never plaintext, never the vt_ token.
      masked = resolve_on_plane(archived, Message, :operator, grant: DenyAll).body
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "SUPPORT-BODY-ARCHIVED-SENTINEL"

      # SABOTAGE twin / anti-tautology.
      assert_leak_detected!("<td>#{body}</td>", body)

      # CONTROL: the tenant plane resolves clear even while archived — trash,
      # not erasure, and masking is a plane/grant gate, not a blanket
      # archived-row mask.
      tenant_resolved = resolve_on_plane(archived, Message, :tenant, repo: Demo.Repo).body
      refute match?(%Samen.Masked{}, tenant_resolved)
      assert to_string(tenant_resolved) == body

      # Restore does not leak.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        Message
        |> Ash.Query.ensure_selected([:body])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == message.id))

      assert_plane_masked!(resolve_on_plane(live, Message, :operator, grant: DenyAll).body)
    end
  end

  # ── INV-1: masking holds on an archived vaulted Agent, restore never leaks ───

  describe "INV-1 — an archived Agent still masks full_name per plane, restore never leaks" do
    test "archived Agent keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      agent = mk_agent(org, first: "Grace", last: "Hopper")

      {:ok, _} = Samen.Archival.archive(agent, authorize?: false)

      archived =
        Agent
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == agent.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived.
      %{rows: [[stored]]} =
        Repo.query!("SELECT sag_full_name FROM sag_agent WHERE sag_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves to %Masked{}.
      masked = resolve_on_plane(archived, Agent, :operator, grant: DenyAll).full_name
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "Hopper"

      # SABOTAGE twin / anti-tautology.
      assert_leak_detected!("<td>Grace Hopper</td>", "Grace Hopper")

      # CONTROL: the tenant plane resolves clear even while archived. The
      # composite-type resolve path returns the raw decrypted value (a JSON
      # encoding of the FullName fields, not a re-cast struct) — check the
      # plaintext names are present rather than an exact struct match.
      tenant_resolved = resolve_on_plane(archived, Agent, :tenant, repo: Demo.Repo).full_name
      refute match?(%Samen.Masked{}, tenant_resolved)
      assert to_string(tenant_resolved) =~ "Grace"
      assert to_string(tenant_resolved) =~ "Hopper"

      # Restore does not leak.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        Agent
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == agent.id))

      assert_plane_masked!(resolve_on_plane(live, Agent, :operator, grant: DenyAll).full_name)
    end
  end
end
