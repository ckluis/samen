defmodule Driftwood.BrokerRoleTest do
  @moduledoc """
  The broker console acts as the signed-in person (`Samen.Web.TenantActor`), not as a fixed member: the role comes from
  the person's active membership, a viewer's page renders no write control and refuses a crafted write event, and a person
  with no membership in the brokerage gets the denied state. Every denial is paired with the member who can.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Operator.{AuthToken, Credential, Invitation, Membership, Org, User}
  alias DriftwoodWeb.BrokerLive
  alias Samen.Identity.{Invite, Register}

  setup do
    prev = Application.get_env(:driftwood, :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:driftwood, :auth_required?, true)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:driftwood, :auth_required?),
        else: Application.put_env(:driftwood, :auth_required?, prev)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    owner = register!()
    %{owner: owner, viewer: accept_into!(owner, :viewer), member: accept_into!(owner, :member), org_id: owner.org.id}
  end

  defp register! do
    attrs = %{
      org_name: "Role Freight #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "broker-role-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} =
      Register.register(attrs, %{
        org: Org,
        credential: Credential,
        user: User,
        membership: Membership,
        auth_token: AuthToken,
        repo: Driftwood.Repo
      })

    Map.put(result, :email, attrs.email)
  end

  defp accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    mods = %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Driftwood.Repo}
    {:ok, _inv, raw} = Invite.create(mods, owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(mods, raw)
    invitee
  end

  # The REAL broker mount off the compiled router, with the principal the tenant gate would pin for `account`.
  defp broker_socket(account, org_id, panel \\ "loads") do
    mount =
      DriftwoodWeb.Router.__routes__()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.find(&(&1.path == "/broker"))
      |> then(fn %{metadata: %{phoenix_live_view: {_v, _a, _o, ls}}} -> get_in(ls, [:extra, :session, "samen_mount"]) end)
      |> Samen.Web.Mount.from_session()

    socket =
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:samen_principal_ref, {:credential, account.credential.id})
      |> Phoenix.Component.assign(org_id: org_id, panel: panel, load_filter: %{status: nil, q: ""})
      |> Phoenix.Component.assign(show_new: false, new_load_form: nil, load_error: nil)

    BrokerLive.load_panel(socket, panel, org_id)
  end

  defp html(socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> BrokerLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = BrokerLive.handle_event(name, params, socket)
    socket
  end

  defp loads(org_id), do: Driftwood.Reads.load_board(broker_scope(org_id))

  @load %{"load" => %{"name" => "LD-1", "lane" => "TX->CA", "rate" => "1200.00", "status" => "open"}}

  test "the page acts as the signed-in person's role, never a fixed member", ctx do
    for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      socket = broker_socket(Map.fetch!(ctx, who), ctx.org_id)
      assert socket.assigns.actor_state == :ok
      assert socket.assigns.acting_scope.actor.role == role
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "a viewer's page renders no write control and refuses a crafted write event; the member's writes", ctx do
    viewer = broker_socket(ctx.viewer, ctx.org_id)
    refute viewer.assigns.can_write
    refute html(viewer) =~ ~s(id="new-load")

    refused = viewer |> event("new_load", %{}) |> event("save_load", @load)
    assert refused.assigns.flash["error"] =~ "can view this brokerage"
    assert loads(ctx.org_id) == []

    member = broker_socket(ctx.member, ctx.org_id)
    assert member.assigns.can_write
    assert html(member) =~ ~s(id="new-load")

    saved = member |> event("new_load", %{}) |> event("save_load", @load)
    assert saved.assigns.flash["info"] == "Load created."
    assert [%{name: "LD-1"}] = loads(ctx.org_id)
  end

  test "a person with no membership in the brokerage gets the denied state and nothing is read or written", ctx do
    stranger = register!()
    socket = broker_socket(stranger, ctx.org_id)

    assert socket.assigns.actor_state == :denied
    assert socket.assigns.acting_scope == nil
    assert socket.assigns.loads == []
    assert html(socket) =~ "actor-denied"

    after_event = socket |> event("new_load", %{}) |> event("save_load", @load)
    assert loads(ctx.org_id) == []
    assert after_event.assigns.acting_scope == nil
  end
end
