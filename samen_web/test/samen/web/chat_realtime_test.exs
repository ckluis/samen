defmodule Samen.Web.ChatRealtimeTest do
  @moduledoc """
  THE REALTIME DELIVERY GATE (ADR-012 §3, test-plan §8.1, red path 3).

  A message is posted on a thread; the send broadcasts an ID-ONLY envelope on the thread's
  `Phoenix.PubSub` topic. TWO subscriber processes on the SAME topic receive it, and each
  RE-READS the message through the reads layer with ITS OWN scope, so the body resolves per the
  RECEIVING viewer's plane:

    * the TENANT subscriber's re-read → the CLEAR body (own plane);
    * the OPERATOR subscriber's re-read → `••••` (masked), from the SAME broadcast.

  This proves masking survives the realtime path BY CONSTRUCTION: a plaintext body NEVER transits
  PubSub (the envelope carries the id, not the body), so a masked operator session cannot receive
  plaintext even by listening on the topic. The `handle_info` re-read is the gating assertion; a
  live two-session drive (§8.1) is belt-and-suspenders.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat
  alias Samen.Web.Chat.PubSub, as: ChatPubSub
  alias Samen.Web.Mount

  @pubsub Samen.WebTest.ChatPubSub

  setup do
    # A real PubSub server for the realtime path (mirrors the host's Driftwood.PubSub).
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id, person_id: seeded.crm.person.id)

    %{org_id: seeded.org_id, chat: chat, person_id: seeded.crm.person.id}
  end

  test "a broadcast reaches a second subscriber; the re-read resolves the body per plane", %{
    org_id: org_id,
    chat: chat
  } do
    # Two mounts pointing at the SAME host chat scope, with the framework PubSub server.
    tenant_mount = chat_mount(plane: :tenant)
    operator_mount = chat_mount(plane: :operator, target_org_id: org_id)

    topic = ChatPubSub.topic(chat.thread.id)

    # A SECOND subscriber process (the operator viewer) subscribes to the topic and relays what
    # it receives back to the test process — proving cross-process realtime delivery.
    test_pid = self()

    operator_subscriber =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(@pubsub, topic)
        send(test_pid, :operator_subscribed)

        receive do
          {:chat_message, envelope} ->
            op_scope = Mount.scope(operator_mount, org_id)
            {:ok, %{message: msg}} = Chat.read_broadcast(operator_mount, op_scope, envelope)
            send(test_pid, {:operator_saw, msg.body})
        after
          5_000 -> send(test_pid, :operator_timeout)
        end
      end)

    # The tenant viewer (this process) also subscribes.
    Phoenix.PubSub.subscribe(@pubsub, topic)
    assert_receive :operator_subscribed, 2_000

    # The tenant posts a NEW message with a ref — this broadcasts the id-only envelope.
    tenant_scope = Mount.scope(tenant_mount, org_id)

    {:ok, posted} =
      Chat.post_message(
        tenant_mount,
        tenant_scope,
        %{
          org_id: org_id,
          thread_id: chat.thread.id,
          participant_id: chat.tenant_participant.id,
          sender_party: :tenant,
          body: "New realtime line — CHAT-BODY-SENTINEL"
        },
        # broadcast via the framework path, but on the test pubsub server (mount label).
        broadcast: true
      )

    # RED PATH 3 — the envelope carries the message id, NEVER the plaintext body.
    envelope = Chat.envelope(posted)
    refute Map.has_key?(envelope, :body)
    assert envelope.message_id == posted.id

    # The TENANT subscriber (this process) receives the broadcast and re-reads → CLEAR body.
    assert_receive {:chat_message, ^envelope}, 2_000
    {:ok, %{message: tenant_msg}} = Chat.read_broadcast(tenant_mount, tenant_scope, envelope)
    assert tenant_msg.body == "New realtime line — CHAT-BODY-SENTINEL"

    # The OPERATOR subscriber (second process) re-read the SAME message → •••• (masked).
    assert_receive {:operator_saw, operator_body}, 3_000
    assert match?(%Samen.Masked{}, operator_body)
    refute is_binary(operator_body) and operator_body =~ "CHAT-BODY-SENTINEL"

    Process.exit(operator_subscriber, :normal)
  end

  test "the id-only envelope carries no resolved body (a listener cannot get plaintext)", %{
    org_id: org_id,
    chat: chat
  } do
    mount = chat_mount(plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)

    envelope = Chat.envelope(chat.message)

    # The envelope is pure ids/refs — no body key at all.
    assert Map.keys(envelope) |> Enum.sort() ==
             [:message_id, :participant_id, :refs, :sender_party, :thread_id]

    # An operator listener re-reading the envelope gets •••• (masked), never the sentinel.
    {:ok, %{message: msg}} = Chat.read_broadcast(mount, scope, envelope)
    assert match?(%Samen.Masked{}, msg.body)
  end

  # -- helpers -----------------------------------------------------------------

  # A chat mount over the test host's Chat scope, with the framework PubSub server on the
  # `:pubsub` label (the host-supplies-data seam).
  defp chat_mount(opts) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator("op-1", Keyword.fetch!(opts, :target_org_id), "test-session")

        _ ->
          Samen.Web.Plane.tenant()
      end

    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: plane, labels: %{pubsub: @pubsub})
  end
end
