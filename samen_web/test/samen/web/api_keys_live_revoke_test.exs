defmodule Samen.Web.ApiKeysLiveRevokeTest do
  @moduledoc """
  PP-6 (Batch 2 TENANT-ROLE) — `Samen.Web.Settings.ApiKeysLive`'s "Revoke" handler threads
  the REAL per-org membership role (the SAME resolution its own "mint" handler uses),
  NOT the synthetic hardcoded-`:member` `Mount.scope/2` default.

  The bug this closes (W6 HIGH-1): the revoke handler built `Mount.scope(mount, org_id)`,
  which hardcodes `role: :member`. `ApiKey.:update` (revoke) is `RoleAtLeast(:admin)`, so
  the policy DENIED every revoke — for EVERY role, including genuine owners/admins — and the
  handler discarded the error, so the key stayed "active" forever with no visible failure.

  Both directions, at the LiveView layer:

    * an ADMIN/OWNER CAN revoke (was silently broken, now works) — RED-was-broken-now-green;
    * a MEMBER CANNOT (correct denial) — the anti-tautology positive/negative control.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.ApiKeys
  alias Samen.Web.Settings.ApiKeysLive

  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.User

  defp mount, do: Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Plane.tenant())

  defp admin_scope(user_id, org_id, role) do
    %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}}
  end

  defp seed_user!(org_id, role, handle) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: handle})
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  # Mint a key under a real admin scope (the mint path is already correct) and return its id.
  defp mint_key!(org_id, admin_user) do
    {:ok, membership} =
      Samen.Web.Settings.Reads.current_membership(
        mount(),
        admin_scope(admin_user.id, org_id, :admin),
        admin_user.id,
        org_id
      )

    {:ok, _raw, row} =
      ApiKeys.mint(mount(), admin_scope(admin_user.id, org_id, :admin),
        membership_id: membership.id,
        minter_role: :admin,
        plane: :tenant,
        scopes: %{all: [:read]}
      )

    row.id
  end

  defp revoke_socket(org_id, user_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:user_id, user_id)
    |> Phoenix.Component.assign(:minted_key, nil)
    |> Phoenix.Component.assign(:keys, [])
  end

  defp fire_revoke(socket, key_id) do
    {:noreply, socket} = ApiKeysLive.handle_event("revoke", %{"id" => key_id}, socket)
    socket
  end

  defp key_revoked?(org_id, admin_user, key_id) do
    ApiKeys.list(mount(), admin_scope(admin_user.id, org_id, :admin))
    |> Enum.find(fn k -> k.id == key_id end)
    |> case do
      nil -> false
      view -> view.revoked?
    end
  end

  describe "revoke uses the REAL per-org role (PP-6)" do
    # RED-was-broken-now-green: an admin's revoke was silently denied by the synthetic
    # `:member` scope; with the real role it succeeds. This is the named MUST_FAIL for the
    # PP-6 sabotage (revert to `Mount.scope` → admin can no longer revoke → this FLIPS).
    test "PP-6: an ADMIN CAN revoke an API key through the LiveView revoke handler" do
      org_id = Ash.UUID.generate()
      admin = seed_user!(org_id, :admin, "admin")
      key_id = mint_key!(org_id, admin)

      refute key_revoked?(org_id, admin, key_id), "precondition: key starts active"

      _socket = revoke_socket(org_id, admin.id) |> fire_revoke(key_id)

      assert key_revoked?(org_id, admin, key_id),
             "an admin must be able to revoke a leaked/compromised key"
    end

    test "PP-6: an OWNER CAN revoke (owner outranks admin)" do
      org_id = Ash.UUID.generate()
      admin = seed_user!(org_id, :admin, "admin")
      owner = seed_user!(org_id, :owner, "owner")
      key_id = mint_key!(org_id, admin)

      _socket = revoke_socket(org_id, owner.id) |> fire_revoke(key_id)

      assert key_revoked?(org_id, admin, key_id)
    end

    # The anti-tautology control: the gate is a ROLE gate, so a member is DENIED — the key
    # stays active (the handler discards the forbidden error; no leak, but no revoke).
    test "PP-6: a MEMBER CANNOT revoke — the key stays active (denied by role)" do
      org_id = Ash.UUID.generate()
      admin = seed_user!(org_id, :admin, "admin")
      member = seed_user!(org_id, :member, "member")
      key_id = mint_key!(org_id, admin)

      _socket = revoke_socket(org_id, member.id) |> fire_revoke(key_id)

      refute key_revoked?(org_id, admin, key_id),
             "a member must NOT be able to revoke an org API key"
    end
  end
end
