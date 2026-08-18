defmodule Samen.Web.ChatIdentityWriteTest do
  @moduledoc """
  The WRITE side of the 3-state identity model (ADR-012 §5), inherited by every host's inbox.

  `chat_identity_states_test.exs` proves the READ precedence (given a stored state, who sees
  what). THIS test proves the framework SEAMS that PRODUCE those states from the inbox UI:

    * `Chat.set_disclosure_setting/3` — the tenant-wide toggle (state 3). Admin-gated; a
      `:tenant_wide` snapshot then stamps NEW threads.
    * `Chat.start_conversation/3` — the new-conversation form. `share_identity: true` stamps the
      thread `:initiator_opt_in` + the initiator participant `identity_shared: true` (state 2);
      `false` snapshots the org setting (`:tenant_wide` when on, else the masked floor).
    * `ThreadsLive.handle_event/3` — the inbox events (`toggle_disclosure`, `new_conversation`)
      run ONLY on the tenant plane; a masked operator inbox cannot flip a setting or open a
      conversation.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Chat
  alias Samen.Web.Chat.{Reads, ThreadsLive}
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id}
  end

  # -- state 3: the tenant-wide disclosure setting -----------------------------

  test "set_disclosure_setting persists the org-wide flag + a NEW thread snapshots :tenant_wide", %{
    org_id: org_id
  } do
    mount = tenant_mount()
    scope = Mount.scope(mount, org_id)

    # Default: no setting → masked floor.
    refute Chat.disclosure_setting?(mount, scope)

    {:ok, _} = Chat.set_disclosure_setting(mount, scope, true)
    assert Chat.disclosure_setting?(mount, scope)

    # A thread created AFTER the flip snapshots :tenant_wide (state 3).
    {:ok, thread} =
      Chat.start_conversation(mount, scope, %{
        org_id: org_id,
        subject: "Post-flip thread",
        handle: "dispatch"
      })

    assert thread.disclosure_mode == :tenant_wide

    # Flipping OFF is idempotent-upsert (updates the single row, not a second row).
    {:ok, _} = Chat.set_disclosure_setting(mount, scope, false)
    refute Chat.disclosure_setting?(mount, scope)
  end

  test "the setting write is admin-gated: a masked OPERATOR cannot flip an org's disclosure", %{
    org_id: org_id
  } do
    mount = operator_mount(org_id)
    op_scope = Mount.scope(mount, org_id)

    # The context's admin-scope path is tenant-only by construction, but assert the operator
    # inbox event itself is a no-op (a masked operator never reaches the write).
    socket = build_socket(ThreadsLive, mount, [org_id])
    {:noreply, socket} = ThreadsLive.handle_event("toggle_disclosure", %{"expose_identity" => "on"}, socket)

    refute socket.assigns.expose_identity
    refute Chat.disclosure_setting?(mount, op_scope)
  end

  # -- state 2: the initiator opt-in on new conversation -----------------------

  test "start_conversation with share_identity: true stamps :initiator_opt_in + shares the initiator", %{
    org_id: org_id
  } do
    mount = tenant_mount()
    scope = Mount.scope(mount, org_id)

    {:ok, thread} =
      Chat.start_conversation(mount, scope, %{
        org_id: org_id,
        subject: "I am sharing my name",
        handle: "dispatch-dana",
        full_name: %Samen.Type.FullName{first: "Dana", last: "Whitfield"},
        share_identity: true
      })

    assert thread.disclosure_mode == :initiator_opt_in

    [participant | _] = Reads.participants(mount, scope, thread.id)
    assert participant.identity_shared == true
    assert participant.party == :tenant
    assert participant.handle == "dispatch-dana"
  end

  test "start_conversation without opt-in falls to the masked floor (no setting)", %{org_id: org_id} do
    mount = tenant_mount()
    scope = Mount.scope(mount, org_id)

    {:ok, thread} =
      Chat.start_conversation(mount, scope, %{
        org_id: org_id,
        subject: "Masked by default",
        handle: "dispatch"
      })

    assert thread.disclosure_mode == :masked

    [participant | _] = Reads.participants(mount, scope, thread.id)
    assert participant.identity_shared == false
  end

  # -- the inbox events (tenant plane only) ------------------------------------

  test "ThreadsLive toggle_disclosure event flips the org setting on the tenant plane", %{org_id: org_id} do
    mount = tenant_mount()
    socket = build_socket(ThreadsLive, mount, [org_id])

    refute socket.assigns.expose_identity

    {:noreply, socket} =
      ThreadsLive.handle_event("toggle_disclosure", %{"expose_identity" => "on"}, socket)

    assert socket.assigns.expose_identity
    assert socket.assigns.flash_note =~ "ON"
    assert Chat.disclosure_setting?(mount, Mount.scope(mount, org_id))
  end

  test "ThreadsLive new_conversation event creates a thread + opt-in participant (tenant plane)", %{
    org_id: org_id
  } do
    mount = tenant_mount()
    socket = build_socket(ThreadsLive, mount, [org_id])
    before = length(socket.assigns.threads)

    {:noreply, socket} =
      ThreadsLive.handle_event(
        "new_conversation",
        %{"subject" => "Started from the inbox", "handle" => "dispatch", "share_identity" => "on"},
        socket
      )

    assert length(socket.assigns.threads) == before + 1
    assert socket.assigns.flash_note =~ "shared YOUR identity"

    scope = Mount.scope(mount, org_id)
    thread = Enum.find(Reads.threads(mount, scope), &(&1.subject == "Started from the inbox"))
    assert thread.disclosure_mode == :initiator_opt_in
  end

  test "an OPERATOR inbox cannot start a conversation (new_conversation is a no-op)", %{org_id: org_id} do
    mount = operator_mount(org_id)
    socket = build_socket(ThreadsLive, mount, [org_id])
    before = length(socket.assigns.threads)

    {:noreply, socket} =
      ThreadsLive.handle_event(
        "new_conversation",
        %{"subject" => "operator should not create this", "handle" => "op"},
        socket
      )

    assert length(socket.assigns.threads) == before
  end

  # -- the inbox render surfaces the controls on the tenant plane --------------

  test "the tenant inbox renders the disclosure toggle + new-conversation form; operator inbox does not", %{
    org_id: org_id
  } do
    tenant_html = render_live(ThreadsLive, tenant_mount(), [org_id])
    assert tenant_html =~ "chat-identity-setting"
    assert tenant_html =~ "chat-new-conversation"
    assert tenant_html =~ "Expose participant identity"
    assert tenant_html =~ "initiator opt-in"

    # T153 — the operator inbox is a per-tenant drill-in: an active impersonation session is
    # required to read it (deny-on-read). Open one (keyed on the plane's operator id "op-1"), so
    # this test still asserts what it always did — the operator inbox lacks the tenant WRITE
    # controls — rather than the denied panel.
    open_impersonation!("op-1", org_id)
    operator_html = render_live(ThreadsLive, operator_mount(org_id), [org_id])
    refute operator_html =~ "chat-identity-setting"
    refute operator_html =~ "chat-new-conversation"
    refute operator_html =~ "no active impersonation session"
  end

  # -- helpers -----------------------------------------------------------------

  defp build_socket(module, mount, load_args) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> then(&apply(module, :load, [&1 | load_args]))
  end

  defp tenant_mount do
    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{title: "Blue Ridge Logistics"}
    )
  end

  defp operator_mount(org_id) do
    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo,
      plane: Samen.Web.Plane.operator("op-1", org_id, "test-session"),
      labels: %{title: "Driftwood Ops"}
    )
  end
end
