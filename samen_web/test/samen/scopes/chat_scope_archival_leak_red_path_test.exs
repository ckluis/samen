defmodule Samen.Scopes.ChatScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the Chat scope (ADR-040 §5.9, T37e): `ChatThread`
  flips `archivable true` and is the cascade PARENT of
  `thread ▸cascade participant ▸cascade message` (§5.4) — mirroring the CMS
  `page ▸cascade block` precedent (T37b) this scope's cascade modules
  (`Samen.Scopes.Chat.CascadeArchive`/`CascadeRestore`) explicitly reuse the shape
  of. `ChatParticipant`/`ChatMessage` are ALSO `archivable true` (substrate only —
  the cascade needs something to set/match/restore), but per the roster's ¶
  footnote ("has NO independent archive: it cascades with its thread only") both
  carry an explicit `policy action([:archive, :restore]) do forbid_if(always())
  end` — proven directly below (§5.4-policy). `ChatDisclosureSetting` stays
  excluded (a live per-org config row — delete is delete).

  §5.3: no `unique_index` exists on `wct_thread` / `wcp_participant` / `wcm_message`
  today (confirmed by inspecting `20260708160000_mount_chat_scope` — zero
  `unique_index` calls) — nothing to convert to partial form.

  §5.5's standing duty — an archived record must not leak via relationship load or
  aggregate — is genuinely constructible here (unlike primitives, which has no
  in-scope relationships at all): `ChatThread.participants`/`ChatThread.messages`
  (the new `has_many` relationships this task added, the inverse of
  `ChatParticipant`/`ChatMessage`'s pre-existing `belongs_to :thread`) and an
  `:exists` aggregate over each.

  INV-1 — the masking-on-archived proof — runs on BOTH of this scope's 🔒 fields:
  `ChatParticipant.full_name` (Done-criterion 5, the roster's named target) AND
  `ChatMessage.body` (the task's own INV-1 instruction: "chat MESSAGES likely
  carry PII (message body) ... archived message STILL MASKS, 3-proof on an
  archived vaulted chat message").
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Samen.WebTest.Chat.{ChatMessage, ChatParticipant, ChatThread}

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_thread(org_id, subject \\ "Thread") do
    {:ok, t} =
      ChatThread
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        subject: "#{subject}-#{:rand.uniform(999_999)}",
        kind: :cross_plane,
        status: :open,
        disclosure_mode: :masked
      })
      |> Ash.create(authorize?: false)

    t
  end

  defp mk_participant(org_id, thread_id, opts \\ []) do
    first = Keyword.get(opts, :first, "Ada")
    last = Keyword.get(opts, :last, "Lovelace-#{:rand.uniform(999_999)}")

    {:ok, p} =
      ChatParticipant
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        thread_id: thread_id,
        party: :tenant,
        principal_kind: :user,
        handle: "handle-#{:rand.uniform(999_999)}",
        role: :member,
        full_name: %Samen.Type.FullName{first: first, last: last}
      })
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_message(org_id, thread_id, participant_id, body \\ nil) do
    {:ok, m} =
      ChatMessage
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        thread_id: thread_id,
        participant_id: participant_id,
        sender_party: :tenant,
        kind: :message,
        body: body || "message body #{:rand.uniform(999_999)}"
      })
      |> Ash.create(authorize?: false)

    m
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

  # T124 same-second regression helper (T37b precedent). Archives an independent
  # sibling message, then IMMEDIATELY (no sleep) archives its parent thread —
  # cascading a DIFFERENT message — via the real production `Samen.Archival.
  # archive/2` path (real `DateTime.utc_now/0` reads, no forced timestamps). Two
  # back-to-back in-process Ecto operations land in the same wall-clock SECOND the
  # overwhelming majority of the time but not deterministically, so this retries
  # with fresh records, bounded, until the two persisted `archived_at` values
  # verifiably fall in the same wall-clock second. Anti-tautology: this criterion
  # is satisfiable/checkable identically whether the T124 substrate fix is present
  # or not — it does NOT assume the bug's own truncated-equality behavior.
  @same_second_max_attempts 40

  defp archive_independent_message_then_thread_same_second!(org, attempt \\ 1) do
    thread = mk_thread(org, "Same-Second")
    cascaded_participant = mk_participant(org, thread.id)
    independent_participant = mk_participant(org, thread.id)
    cascaded_message = mk_message(org, thread.id, cascaded_participant.id)
    independent_message = mk_message(org, thread.id, independent_participant.id)

    {:ok, archived_independent} = Samen.Archival.archive(independent_message, authorize?: false)
    {:ok, archived_thread} = Samen.Archival.archive(thread, authorize?: false)

    if DateTime.truncate(archived_independent.archived_at, :second) ==
         DateTime.truncate(archived_thread.archived_at, :second) do
      %{
        thread: archived_thread,
        cascaded_message: cascaded_message,
        independent_message: archived_independent
      }
    else
      if attempt >= @same_second_max_attempts do
        flunk(
          "could not reproduce a same-wall-clock-second archive collision after " <>
            "#{@same_second_max_attempts} attempts — environment too slow for this " <>
            "regression test to exercise the T124 same-second edge"
        )
      else
        archive_independent_message_then_thread_same_second!(org, attempt + 1)
      end
    end
  end

  # ── introspection: the adopt-me convention landed on the roster row ────────

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "thread/participant/message report true; disclosure_setting reports false" do
      assert Samen.Info.archivable?(ChatThread)
      assert Samen.Info.archivable?(ChatParticipant)
      assert Samen.Info.archivable?(ChatMessage)
      refute Samen.Info.archivable?(Samen.WebTest.Chat.ChatDisclosureSetting)
    end
  end

  # ── c1: archive/restore round trip for Thread (actor-reachable via cascade owner) ─

  describe "c1 — archive removes Thread from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
    test "for thread" do
      org = mk_org()
      thread = mk_thread(org)

      assert MapSet.member?(live_ids(ChatThread, org), thread.id)

      {:ok, _} = Samen.Archival.archive(thread, authorize?: false)

      refute MapSet.member?(live_ids(ChatThread, org), thread.id)
      assert MapSet.member?(archived_ids(ChatThread, org), thread.id)

      {:ok, _} = Samen.Archival.restore(archived_record(ChatThread, thread.id), authorize?: false)
      assert MapSet.member?(live_ids(ChatThread, org), thread.id)
      refute MapSet.member?(archived_ids(ChatThread, org), thread.id)
    end
  end

  # ── §5.4-policy: participant/message have NO independent archive for a real actor ─

  describe "§5.4 ¶ — an actor-driven :archive/:restore on Participant/Message is refused" do
    test "a real org-scoped member actor cannot call :archive on a Participant directly" do
      org = mk_org()
      thread = mk_thread(org)
      participant = mk_participant(org, thread.id)
      actor = %{org_id: org, role: :member}

      result =
        participant
        |> Ash.Changeset.for_destroy(:archive, %{}, actor: actor)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "a real org-scoped member actor cannot call :archive on a Message directly" do
      org = mk_org()
      thread = mk_thread(org)
      participant = mk_participant(org, thread.id)
      message = mk_message(org, thread.id, participant.id)
      actor = %{org_id: org, role: :member}

      result =
        message
        |> Ash.Changeset.for_destroy(:archive, %{}, actor: actor)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "the SAME actor CAN archive the Thread itself (CONTROL — proves the forbid above is Participant/Message-specific, not a blanket deny)" do
      org = mk_org()
      thread = mk_thread(org)
      actor = %{org_id: org, role: :member}

      assert {:ok, _} = Samen.Archival.archive(thread, actor: actor)
    end
  end

  # ── §5.4 cascade: thread ▸cascade {participant, message} — same-instant archive ─

  describe "§5.4 — archiving a Thread cascades to archive its Participants AND Messages at the same instant" do
    test "both members land on the EXACT same archived_at as the thread (RED: hidden; CONTROL: unrelated thread untouched)" do
      org = mk_org()
      thread = mk_thread(org, "Cascade Archive")
      other_thread = mk_thread(org, "Untouched")

      participant = mk_participant(org, thread.id)
      other_participant = mk_participant(org, other_thread.id)

      message = mk_message(org, thread.id, participant.id)
      other_message = mk_message(org, other_thread.id, other_participant.id)

      {:ok, archived_thread} = Samen.Archival.archive(thread, authorize?: false)

      # RED: both cascaded members vanish from their default reads.
      refute MapSet.member?(live_ids(ChatParticipant, org), participant.id)
      refute MapSet.member?(live_ids(ChatMessage, org), message.id)
      # CONTROL: an unrelated thread's members are untouched.
      assert MapSet.member?(live_ids(ChatParticipant, org), other_participant.id)
      assert MapSet.member?(live_ids(ChatMessage, org), other_message.id)

      archived_participant = archived_record(ChatParticipant, participant.id)
      archived_message = archived_record(ChatMessage, message.id)

      assert archived_participant.archived_at == archived_thread.archived_at
      assert archived_message.archived_at == archived_thread.archived_at
    end
  end

  # ── §5.4 cascade: same-instant restore match (>1s independent gap) ─────────

  describe "§5.4 — restoring a Thread restores exactly the same-instant-archived members" do
    test "a message archived independently BEFORE the thread's cascade stays archived after the thread restores (RED); the cascaded message returns (CONTROL)" do
      org = mk_org()
      thread = mk_thread(org, "Cascade Restore")

      cascaded_participant = mk_participant(org, thread.id)
      independent_participant = mk_participant(org, thread.id)
      cascaded_message = mk_message(org, thread.id, cascaded_participant.id)
      independently_archived_message = mk_message(org, thread.id, independent_participant.id)

      # Archive the second message INDEPENDENTLY first, at its own instant.
      {:ok, _} = Samen.Archival.archive(independently_archived_message, authorize?: false)

      # Force a distinct instant with a >1s sleep — belt-and-suspenders on top of
      # T124's microsecond fix (see the no-sleep same-second test below for the
      # direct edge reproduction).
      Process.sleep(1_100)

      {:ok, archived_thread} = Samen.Archival.archive(thread, authorize?: false)

      cascaded_before = archived_record(ChatMessage, cascaded_message.id)
      independent_before = archived_record(ChatMessage, independently_archived_message.id)

      assert cascaded_before.archived_at == archived_thread.archived_at
      refute independent_before.archived_at == archived_thread.archived_at

      {:ok, _} = Samen.Archival.restore(archived_thread, authorize?: false)

      # CONTROL: the cascade-archived message came back with the thread.
      assert MapSet.member?(live_ids(ChatMessage, org), cascaded_message.id)
      # RED: the independently-archived message did NOT — different instant, not
      # part of the cascade set (ADR-040 §5.4).
      refute MapSet.member?(live_ids(ChatMessage, org), independently_archived_message.id)
      assert MapSet.member?(archived_ids(ChatMessage, org), independently_archived_message.id)
    end
  end

  # ── §5.4 cascade: same wall-clock second (T124, mirrors T37b's F1 regression) ─

  describe "§5.4 — same wall-clock second (T124)" do
    test "thread restore does not mis-restore an independently-archived same-second sibling message (CONTROL: cascade message restores)" do
      org = mk_org()

      %{thread: archived_thread, cascaded_message: cascaded_message, independent_message: archived_independent} =
        archive_independent_message_then_thread_same_second!(org)

      # Sanity: we really did land in the same wall-clock second.
      assert DateTime.truncate(archived_independent.archived_at, :second) ==
               DateTime.truncate(archived_thread.archived_at, :second)

      # Under the pre-T124 substrate (`archived_at` silently second-granular
      # regardless of column type), the two persisted instants would be
      # byte-IDENTICAL here — exactly what would let the cascade restore's
      # `archived_at == ^instant` match sweep up the independent message too.
      # Post-T124 (true microsecond precision), they are practically guaranteed
      # to differ.
      independent_collided_with_thread? =
        archived_independent.archived_at == archived_thread.archived_at

      {:ok, _restored_thread} = Samen.Archival.restore(archived_thread, authorize?: false)

      live_message_ids = live_ids(ChatMessage, org)

      # CONTROL (anti-tautology, positive control): the cascade-matched message —
      # same thread, cascaded at the SAME instant as the thread's own archive —
      # DOES come back. Proves the restore path itself works and this test isn't
      # vacuously green because nothing ever restores.
      assert MapSet.member?(live_message_ids, cascaded_message.id)

      # RED (the T37b-style edge, closed by T124): the sibling message archived
      # INDEPENDENTLY — merely in the same wall-clock second as the thread's
      # cascade, not part of the cascade set — must NOT be restored by the thread
      # restore.
      refute independent_collided_with_thread?,
             "pre-T124 defect reproduced: independent message's archived_at collided " <>
               "byte-exact with the thread's cascade instant (second-granularity truncation)"

      refute MapSet.member?(live_message_ids, archived_independent.id)
      assert MapSet.member?(archived_ids(ChatMessage, org), archived_independent.id)
    end
  end

  # ── §5.5 leak duty: relationship load — ChatThread.participants / .messages ─

  describe "§5.5 — an archived Thread's members do not leak via relationship load" do
    test "Thread.participants / Thread.messages resolve empty for an archived thread (RED); a live thread's members surface (CONTROL)" do
      org = mk_org()
      archived_thread = mk_thread(org, "Archived")
      live_thread = mk_thread(org, "Live")

      archived_participant = mk_participant(org, archived_thread.id)
      _archived_message = mk_message(org, archived_thread.id, archived_participant.id)

      live_participant = mk_participant(org, live_thread.id)
      _live_message = mk_message(org, live_thread.id, live_participant.id)

      {:ok, _} = Samen.Archival.archive(archived_thread, authorize?: false)

      loaded_archived =
        ChatThread
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^archived_thread.id)
        |> Ash.Query.load([:participants, :messages])
        |> Ash.read_one!(authorize?: false)

      assert loaded_archived.participants == []
      assert loaded_archived.messages == []

      # CONTROL (anti-tautology): the identical relationship load path on a LIVE
      # thread surfaces its members — proves the empty lists above are the
      # archival filter firing (both the thread AND its cascaded members are
      # archived — either alone would already empty these lists via FilterArchived
      # on the child side), not a structurally broken relationship.
      loaded_live =
        ChatThread |> Ash.get!(live_thread.id, authorize?: false, load: [:participants, :messages])

      assert [%ChatParticipant{id: pid}] = loaded_live.participants
      assert pid == live_participant.id
      assert length(loaded_live.messages) == 1
    end
  end

  describe "§5.5 — an archived Thread's members do not leak via an :exists aggregate" do
    test "the :exists aggregate over Thread.participants/.messages is false for an archived thread (RED); true for a live one (CONTROL)" do
      org = mk_org()
      archived_thread = mk_thread(org, "Archived-Agg")
      live_thread = mk_thread(org, "Live-Agg")

      archived_participant = mk_participant(org, archived_thread.id)
      mk_message(org, archived_thread.id, archived_participant.id)

      live_participant = mk_participant(org, live_thread.id)
      mk_message(org, live_thread.id, live_participant.id)

      {:ok, _} = Samen.Archival.archive(archived_thread, authorize?: false)

      # The parent read itself must go through the :archived (include) read since
      # the default read already hides the archived thread — the aggregate is
      # evaluated ON the thread row, over ITS children's own default-filtered
      # relationship path.
      {:ok, archived_result} =
        ChatThread
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^archived_thread.id)
        |> Ash.Query.aggregate(:participants_live?, :exists, :participants)
        |> Ash.Query.aggregate(:messages_live?, :exists, :messages)
        |> Ash.read_one(authorize?: false)

      refute archived_result.aggregates.participants_live?
      refute archived_result.aggregates.messages_live?

      # CONTROL (anti-tautology): the identical aggregate over a LIVE thread
      # reports true — proves `false` above is the archival filter firing, not
      # the aggregate being vacuously false.
      {:ok, live_result} =
        ChatThread
        |> Ash.Query.filter(id == ^live_thread.id)
        |> Ash.Query.aggregate(:participants_live?, :exists, :participants)
        |> Ash.Query.aggregate(:messages_live?, :exists, :messages)
        |> Ash.read_one(authorize?: false)

      assert live_result.aggregates.participants_live?
      assert live_result.aggregates.messages_live?
    end
  end

  # ── INV-1: masking holds on an archived vaulted Participant, restore never leaks ─

  describe "INV-1 — an archived Participant still masks full_name per plane, restore never leaks" do
    test "archived Participant keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      thread = mk_thread(org)
      participant = mk_participant(org, thread.id, first: "Grace", last: "Hopper")

      {:ok, _} = Samen.Archival.archive(participant, authorize?: false)

      archived =
        ChatParticipant
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == participant.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived —
      # trash, not erasure (§5.1).
      %{rows: [[stored]]} =
        Repo.query!("SELECT wcp_full_name FROM wcp_participant WHERE wcp_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves to %Masked{} — never
      # plaintext, never the vt_ token.
      masked = resolve_on_plane(archived, ChatParticipant, :operator, grant: DenyAll).full_name
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "Hopper"

      # SABOTAGE twin / anti-tautology.
      assert_leak_detected!("<td>Grace Hopper</td>", "Grace Hopper")

      # Restore does not leak.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        ChatParticipant
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == participant.id))

      assert_plane_masked!(resolve_on_plane(live, ChatParticipant, :operator, grant: DenyAll).full_name)
    end
  end

  # ── INV-1: masking holds on an archived vaulted Message, restore never leaks ──

  describe "INV-1 — an archived Message still masks body per plane, restore never leaks" do
    test "archived Message keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      thread = mk_thread(org)
      participant = mk_participant(org, thread.id)
      body = "CHAT-BODY-ARCHIVED-SENTINEL confidential rate details"
      message = mk_message(org, thread.id, participant.id, body)

      {:ok, _} = Samen.Archival.archive(message, authorize?: false)

      archived =
        ChatMessage
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:body])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == message.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived.
      %{rows: [[stored]]} =
        Repo.query!("SELECT pii_wcm_body FROM wcm_message WHERE wcm_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves to %Masked{}.
      masked = resolve_on_plane(archived, ChatMessage, :operator, grant: DenyAll).body
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "CHAT-BODY-ARCHIVED-SENTINEL"

      # SABOTAGE twin / anti-tautology.
      assert_leak_detected!("<td>#{body}</td>", body)

      # CONTROL: the tenant plane resolves clear even while archived. ChatMessage's
      # PII resolution is disclosure-aware (ADR-012 §5), so — unlike a plain
      # OrgScope-only resource — it needs a full tenant actor (`org_id`/`kind`), not
      # just `plane: :tenant` (mirrors `Samen.Scopes.ChatScopeArchivalLeakRedPathTest`
      # sibling `chat_scope_test.exs`'s own tenant-plane actor shape).
      tenant_actor = %{id: "t", org_id: org, role: :member, kind: :tenant, plane: :tenant}

      [tenant_resolved_record] =
        Samen.Api.PiiResolution.resolve([archived], ChatMessage, tenant_actor,
          repo: Samen.WebTest.Repo
        )

      tenant_resolved = tenant_resolved_record.body
      refute match?(%Samen.Masked{}, tenant_resolved)
      assert tenant_resolved == body

      # Restore does not leak.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        ChatMessage
        |> Ash.Query.ensure_selected([:body])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == message.id))

      assert_plane_masked!(resolve_on_plane(live, ChatMessage, :operator, grant: DenyAll).body)
    end
  end
end
