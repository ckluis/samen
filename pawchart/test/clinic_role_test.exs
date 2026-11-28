defmodule PawChart.ClinicRoleTest do
  @moduledoc """
  The clinic page acts as the signed-in person (`Samen.Web.TenantActor`), not as a fixed member: the role comes from the
  person's active membership, a viewer's page renders no write control and refuses a crafted write event, and a person with
  no membership in the clinic gets the denied state. Every denial is paired with the member who can.
  """
  use PawChart.DataCase, async: false



  alias PawChart.Operator, as: Op
  alias PawChartWeb.ClinicLive
  alias Samen.Identity.{Invite, Register}

  setup do
    prev = Application.get_env(:pawchart, :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:pawchart, :auth_required?, true)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:pawchart, :auth_required?),
        else: Application.put_env(:pawchart, :auth_required?, prev)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    owner = register!()
    %{owner: owner, viewer: accept_into!(owner, :viewer), member: accept_into!(owner, :member), org_id: owner.org.id}
  end

  defp register! do
    attrs = %{
      org_name: "Role Clinic #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "clinic-role-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} =
      Register.register(attrs, %{
        org: Op.Org,
        credential: Op.Credential,
        user: Op.User,
        membership: Op.Membership,
        auth_token: Op.AuthToken,
        repo: PawChart.Repo
      })

    Map.put(result, :email, attrs.email)
  end

  defp accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    mods = %{invitation: Op.Invitation, credential: Op.Credential, user: Op.User, membership: Op.Membership, repo: PawChart.Repo}
    {:ok, _inv, raw} = Invite.create(mods, owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(mods, raw)
    invitee
  end

  # The REAL clinic mount off the compiled router, with the principal the tenant gate would pin for `account`.
  defp clinic_socket(account, org_id) do
    mount =
      PawChartWeb.Router.__routes__()
      |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
      |> Enum.find(&(&1.path == "/clinic"))
      |> then(fn %{metadata: %{phoenix_live_view: {_v, _a, _o, ls}}} -> get_in(ls, [:extra, :session, "samen_mount"]) end)
      |> Samen.Web.Mount.from_session()

    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:samen_principal_ref, {:credential, account.credential.id})
    |> ClinicLive.load(org_id, %{})
  end

  defp html(socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> ClinicLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ClinicLive.handle_event(name, params, socket)
    socket
  end

  defp patients(org_id) do
    PawChart.Clinic.Patient
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  @owner_params %{"owner" => %{"first" => "Pat", "last" => "Ient", "email" => "pat@example.test", "phone" => ""}}

  test "the page acts as the signed-in person's role, never a fixed member", ctx do
    for {who, role} <- [viewer: :viewer, member: :member, owner: :owner] do
      socket = clinic_socket(Map.fetch!(ctx, who), ctx.org_id)
      assert socket.assigns.actor_state == :ok
      assert socket.assigns.acting_scope.actor.role == role
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "clinic:")
    end
  end

  test "a viewer's page renders no write control and refuses a crafted write event; the member's writes", ctx do
    viewer = clinic_socket(ctx.viewer, ctx.org_id)
    refute viewer.assigns.can_write
    refute html(viewer) =~ ~s(phx-click="new_owner")

    refused = viewer |> event("new_owner", %{}) |> event("save_owner", @owner_params)
    assert refused.assigns.flash["error"] =~ "can view this clinic"
    assert patients(ctx.org_id) == []

    member = clinic_socket(ctx.member, ctx.org_id)
    assert member.assigns.can_write
    assert html(member) =~ ~s(phx-click="new_owner")

    saved = member |> event("new_owner", %{}) |> event("save_owner", @owner_params)
    assert saved.assigns.flash["info"] == "Patient saved."
    assert [_one] = patients(ctx.org_id)
  end

  test "a person with no membership in the clinic gets the denied state and nothing is read or written", ctx do
    stranger = register!()
    socket = clinic_socket(stranger, ctx.org_id)

    assert socket.assigns.actor_state == :denied
    assert socket.assigns.acting_scope == nil
    assert socket.assigns.owners == []
    assert html(socket) =~ "actor-denied"

    after_event = event(socket, "save_owner", @owner_params)
    assert patients(ctx.org_id) == []
    assert after_event.assigns.acting_scope == nil
  end
end
