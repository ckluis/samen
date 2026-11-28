defmodule Samen.Web.SettingsMembershipStatusTest do
  @moduledoc """
  The settings/wizard role is resolved from the caller's membership (`Samen.Web.Settings.Reads.current_membership_result/4`,
  the one resolver behind the onboarding plan step, the API-key, invitation, billing and reveal-approval screens). A
  membership that is not ACTIVE (suspended, invited) grants no authority: a suspended owner is "no membership in
  context", exactly as for a key's minter (`Samen.Scope.ApiKey.effective_role/2`). Each RED is paired with the
  active-owner control.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.ApiKeys
  alias Samen.Web.Settings.ApiKeysLive
  alias Samen.Web.Settings.Reads
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  def plans(_org_id), do: [%{key: "free", label: "Free"}, %{key: "pro", label: "Pro"}]

  defp mount(labels \\ %{}), do: Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Plane.tenant(), labels: labels)

  defp scope(user_id, org_id, role), do: %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}}

  defp seed_org!, do: Org |> Ash.Changeset.for_create(:create, %{name: "Status Co #{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()

  defp seed_member!(org_id, role, status) do
    user = User |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "m-#{System.unique_integer([:positive])}"}, authorize?: false) |> Ash.create!()

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role, status: status}, authorize?: false)
    |> Ash.create!()

    user
  end

  test "RED: a suspended or invited membership resolves to no membership; CONTROL: the active one resolves with its role" do
    org = seed_org!()
    active = seed_member!(org.id, :owner, "active")
    suspended = seed_member!(org.id, :owner, "suspended")
    invited = seed_member!(org.id, :owner, "invited")

    s = Mount.scope(mount(), org.id)
    assert {:ok, %{role: :owner, status: "active"}} = Reads.current_membership_result(mount(), s, active.id, org.id)
    assert {:error, :not_found} = Reads.current_membership_result(mount(), s, suspended.id, org.id)
    assert {:error, :not_found} = Reads.current_membership_result(mount(), s, invited.id, org.id)
    assert {:error, :not_found} = Reads.current_membership(mount(), s, suspended.id, org.id)
  end

  test "RED: a suspended owner at the plan step is refused (the wizard's role comes from the membership); CONTROL: the active owner selects a plan" do
    for {status, expect} <- [{"suspended", :refused}, {"active", :selected}] do
      org = seed_org!()
      owner = seed_member!(org.id, :owner, status)
      m = mount(%{plan_labels: {__MODULE__, :plans, []}})

      role =
        case Reads.current_membership_result(m, Mount.scope(m, org.id), owner.id, org.id) do
          {:ok, %{role: role}} -> role
          _ -> nil
        end

      result = Samen.Web.Onboarding.select_plan(m, scope(owner.id, org.id, role), org.id, "pro")

      case expect do
        :refused -> assert {:error, :forbidden} = result
        :selected -> assert {:ok, %{plan: "pro"}} = result
      end
    end
  end

  test "RED: a suspended owner cannot revoke an API key through the settings screen; CONTROL: the active owner can" do
    org = seed_org!()
    admin = seed_member!(org.id, :admin, "active")
    suspended = seed_member!(org.id, :owner, "suspended")
    active = seed_member!(org.id, :owner, "active")

    mint = fn ->
      {:ok, membership} = Reads.current_membership(mount(), scope(admin.id, org.id, :admin), admin.id, org.id)

      {:ok, _raw, row} =
        ApiKeys.mint(mount(), scope(admin.id, org.id, :admin), membership_id: membership.id, minter_role: :admin, plane: :tenant, scopes: %{all: [:read]})

      row.id
    end

    revoked? = fn key_id ->
      ApiKeys.list(mount(), scope(admin.id, org.id, :admin)) |> Enum.find(&(&1.id == key_id)) |> Map.fetch!(:revoked?)
    end

    socket = fn user_id ->
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount())
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:org_id, org.id)
      |> Phoenix.Component.assign(:user_id, user_id)
      |> Phoenix.Component.assign(:minted_key, nil)
      |> Phoenix.Component.assign(:keys, [])
      # the page's own load resolves who acts (`Samen.Web.TenantActor`), as a mounted page has before any event
      |> ApiKeysLive.load(org.id, user_id)
    end

    key = mint.()
    {:noreply, _} = ApiKeysLive.handle_event("revoke", %{"id" => key}, socket.(suspended.id))
    refute revoked?.(key), "a suspended owner must not revoke a key"

    {:noreply, _} = ApiKeysLive.handle_event("revoke", %{"id" => key}, socket.(active.id))
    assert revoked?.(key)
  end
end
