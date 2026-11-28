defmodule Demo.IdentityCatalogBehaviourTest do
  @moduledoc """
  B1 identity catalog text, pinned to behaviour.

  Each test reads a security-relevant sentence from demo's live catalog (`Samen.AI.Catalog.schema/0`)
  and, next to it, runs the real action through the real policy stack on demo's mounted Identity
  resources. If the code stops doing what a sentence says, the behaviour assertion fails; if the
  sentence is edited away from the behaviour, the wording assertion fails. Every RED step pairs with
  a CONTROL, so a denial is never a vacuous pass.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.Identity.{ApiKey, Invitation, Membership, Org, User}
  alias Samen.AI.Catalog

  # An approving reveal-grant checker: the operator-with-grant positive control.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  defp described(table, field) do
    Catalog.schema()["tables"]
    |> Enum.find(&(&1["table_name"] == table))
    |> Map.fetch!("fields")
    |> Enum.find(&(&1["logical_name"] == field))
    |> Map.fetch!("description")
  end

  defp resource_text(table), do: Enum.find(Catalog.schema()["tables"], &(&1["table_name"] == table))["description"]

  defp n, do: System.unique_integer([:positive])

  defp mk_org(slug \\ nil) do
    Org
    |> Ash.Changeset.for_create(:create, %{name: "b1-#{n()}", slug: slug})
    |> Ash.create!(authorize?: false)
  end

  defp mk_user(org, attrs) do
    {cred, attrs} = Map.pop(attrs, :credential_id)

    User
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org.id, handle: "u-#{n()}"}, attrs))
    |> then(&if cred, do: Ash.Changeset.force_change_attribute(&1, :credential_id, cred), else: &1)
    |> Ash.create!(authorize?: false)
  end

  defp mk_member(org, role, attrs \\ %{}) do
    user = mk_user(org, attrs)

    mbr =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: user.id, role: role})
      |> Ash.create!(authorize?: false)

    %{user: user, membership: mbr}
  end

  defp actor(org, member, role, extra \\ %{}) do
    Map.merge(%{id: member.user.id, org_id: org.id, role: role, verified?: true, kind: :tenant, plane: :tenant}, extra)
  end

  defp role_of(id), do: Membership |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false) |> Map.fetch!(:role)

  defp upd(record, action, attrs, actor),
    do: record |> Ash.Changeset.for_update(action, attrs, actor: actor) |> Ash.update(actor: actor)

  test "Membership: a write must out-rank the stored role as well as the role set, and a user holds one membership per org" do
    assert resource_text("mbs_membership") =~ "a create is refused when the user already has a membership there"
    assert resource_text("mbs_membership") =~ "any role being set and any role the row holds must each be strictly below the writer's own"
    assert described("mbs_membership", "role") =~ "changing or deleting a row also needs its stored role strictly below"
    assert described("mbs_membership", "status") =~ "Only an active membership resolves a role in the organization for a signed-in session or an API key"
    assert described("mbs_membership", "status") =~ "any other status resolves none"

    org = mk_org()
    owner = mk_member(org, :owner)
    peer = mk_member(org, :admin)
    lower = mk_member(org, :member)
    admin = actor(org, mk_member(org, :admin), :admin)

    # RED: an admin cannot demote or suspend an owner or a peer admin, nor delete them
    assert {:error, %Ash.Error.Forbidden{}} = upd(owner.membership, :update, %{role: :member}, admin)
    assert {:error, %Ash.Error.Forbidden{}} = upd(owner.membership, :update, %{status: "suspended"}, admin)
    assert {:error, %Ash.Error.Forbidden{}} = upd(peer.membership, :update, %{role: :viewer}, admin)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(peer.membership, actor: admin)
    assert role_of(owner.membership.id) == :owner
    assert role_of(peer.membership.id) == :admin

    # RED: a second membership for the same user is refused at create, whatever its role
    second = Membership |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: owner.user.id, role: :viewer})
    assert {:error, %Ash.Error.Invalid{} = refused} = Ash.create(second, actor: admin)
    assert Exception.message(refused) =~ ~r/already|membership/i
    assert [_one] = Membership |> Ash.Query.filter(user_id == ^owner.user.id) |> Ash.read!(authorize?: false)

    # CONTROL (same test): a fresh user with no membership can be added by the same actor
    fresh = mk_user(org, %{})
    assert {:ok, %{role: :viewer}} =
             Membership
             |> Ash.Changeset.for_create(:create, %{org_id: org.id, user_id: fresh.id, role: :viewer})
             |> Ash.create(actor: admin)

    # CONTROL: the same actor demotes a lower-ranked member, and an owner demotes an admin
    assert {:ok, %{role: :viewer}} = upd(lower.membership, :update, %{role: :viewer}, admin)
    assert {:ok, %{role: :member}} = upd(peer.membership, :update, %{role: :member}, actor(org, owner, :owner))
  end

  test "Membership status: only an active membership resolves a role for a session's credential; any other status resolves none" do
    org = mk_org()
    cred = Ash.UUID.generate()
    %{membership: mbr} = mk_member(org, :admin, %{credential_id: cred})
    mods = %{user: User, membership: Membership}

    # CONTROL: active resolves the role and the org
    assert {:ok, %{role: :admin, org_id: org_id}} = Samen.Auth.OrgActor.resolve(mods, cred, org.id)
    assert org_id == org.id
    assert org.id in Samen.Auth.OrgActor.authorized_org_ids(mods, cred)

    # RED: any other status resolves no role and no org
    for status <- ["suspended", "invited"] do
      {:ok, _} = mbr |> Ash.Changeset.for_update(:update, %{status: status}, authorize?: false) |> Ash.update()
      assert :error = Samen.Auth.OrgActor.resolve(mods, cred, org.id), "status #{status} still resolved a role"
      refute org.id in Samen.Auth.OrgActor.authorized_org_ids(mods, cred)
    end

    {:ok, _} = Ash.get!(Membership, mbr.id, authorize?: false) |> Ash.Changeset.for_update(:update, %{status: "active"}, authorize?: false) |> Ash.update()
    assert {:ok, %{role: :admin}} = Samen.Auth.OrgActor.resolve(mods, cred, org.id)
  end

  test "ApiKey: expiry is clamped at create and only shortened by update, revoke is one-way, mark_used is system-only" do
    assert described("key_api_key", "expires_at") =~ "Create clamps it to at most 365 days ahead (90 days when empty)"
    assert described("key_api_key", "expires_at") =~ "an update that sets it can only shorten it and refuses a revoked or expired key"
    assert described("key_api_key", "revoked_at") =~ "the revoke action sets it once and keeps the original instant on a repeat"
    assert described("key_api_key", "last_used_at") =~ "through the system-only mark_used action"
    # a key acts with the lower of its scopes and its role; the scopes are enforced (api_key_scope_enforcement_test.exs)
    assert described("key_api_key", "scopes") =~ "needs a scope that covers the action and a role that allows it"

    org = mk_org()
    admin_member = mk_member(org, :admin)
    admin = actor(org, admin_member, :admin)
    far = DateTime.add(DateTime.utc_now(), 1000, :day)

    mint = fn attrs ->
      ApiKey
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{org_id: org.id, membership_id: admin_member.membership.id, minter_role: :admin, scopes: %{"all" => ["read"]}}, attrs),
        actor: admin
      )
      |> Ash.Changeset.force_change_attribute(:token_digest, "b1-#{n()}")
      |> Ash.create!(actor: admin)
    end

    # create: beyond 365 days clamps down; empty becomes 90 days
    assert DateTime.diff(mint.(%{expires_at: far}).expires_at, DateTime.utc_now(), :day) in 364..365
    key = mint.(%{})
    assert DateTime.diff(key.expires_at, DateTime.utc_now(), :day) in 89..90

    # update: a later instant is ignored (never extends); an earlier one shortens
    stored = key.expires_at
    {:ok, _} = upd(key, :update, %{expires_at: far}, admin)
    assert Ash.get!(ApiKey, key.id, authorize?: false).expires_at == stored
    sooner = DateTime.add(stored, -10, :day) |> DateTime.truncate(:second)
    {:ok, _} = upd(Ash.get!(ApiKey, key.id, authorize?: false), :update, %{expires_at: sooner}, admin)
    assert Ash.get!(ApiKey, key.id, authorize?: false).expires_at == sooner

    # revoke: sets the instant once; a repeat (a second later) keeps it; a revoked key can no longer be re-timed
    {:ok, revoked} = upd(Ash.get!(ApiKey, key.id, authorize?: false), :revoke, %{}, admin)
    assert %DateTime{} = revoked.revoked_at
    Process.sleep(1100)
    {:ok, again} = upd(Ash.get!(ApiKey, key.id, authorize?: false), :revoke, %{}, admin)
    assert again.revoked_at == revoked.revoked_at
    assert {:error, retimed} = upd(Ash.get!(ApiKey, key.id, authorize?: false), :update, %{expires_at: DateTime.add(sooner, -1, :day)}, admin)
    assert Exception.message(retimed) =~ ~r/stale|not found|StaleRecord/i
    # CONTROL: the same re-time on a live key succeeds
    live = mint.(%{})
    assert {:ok, _} = upd(live, :update, %{expires_at: DateTime.add(live.expires_at, -1, :day) |> DateTime.truncate(:second)}, admin)

    # mark_used: no actor, an admin included, may run it; the auth path (no actor) stamps it
    fresh = mint.(%{})
    stamped = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:error, %Ash.Error.Forbidden{}} = upd(fresh, :mark_used, %{last_used_at: stamped}, admin)
    assert Ash.get!(ApiKey, fresh.id, authorize?: false).last_used_at == nil
    assert {:ok, %{last_used_at: ^stamped}} = fresh |> Ash.Changeset.for_update(:mark_used, %{last_used_at: stamped}) |> Ash.update(authorize?: false)
  end

  test "Invitation: every create is pending with a 14-day expiry, status is not an input, update is refused, revoke only while pending" do
    assert resource_text("inv_invitation") =~ "Every create is pending with a 14-day expiry"
    assert resource_text("inv_invitation") =~ "revoked or expired, each only from pending"
    assert described("inv_invitation", "expires_at") =~ "14 days after creation, set by every create"
    assert described("inv_invitation", "status") =~ "pending by default and on every create"
    assert described("inv_invitation", "role") =~ "Creating needs a verified admin or owner and a role strictly below their own"

    org = mk_org()
    admin = actor(org, mk_member(org, :admin), :admin)
    owner = actor(org, mk_member(org, :owner), :owner)

    create = fn attrs, actor ->
      Invitation
      |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org.id, role: :member, email: ["b1-#{n()}@example.test"]}, attrs), actor: actor)
      |> Ash.create(actor: actor)
    end

    # RED: status and expires_at are not inputs; CONTROL: without them the row is pending and expires in 14 days
    assert {:error, %Ash.Error.Invalid{}} = create.(%{status: "accepted"}, admin)
    assert {:error, %Ash.Error.Invalid{}} = create.(%{expires_at: DateTime.add(DateTime.utc_now(), 3650, :day)}, admin)
    {:ok, inv} = create.(%{}, admin)
    row = Ash.get!(Invitation, inv.id, authorize?: false)
    assert row.status == "pending"
    assert DateTime.diff(row.expires_at, DateTime.utc_now(), :day) in 13..14

    # RED: an admin cannot invite an admin, an unverified admin cannot invite at all; CONTROL: an owner can invite an admin
    assert {:error, %Ash.Error.Forbidden{}} = create.(%{role: :admin}, admin)
    assert {:error, %Ash.Error.Forbidden{}} = create.(%{}, %{admin | verified?: false})
    assert {:ok, _} = create.(%{role: :admin}, owner)

    # RED: no actor edits an invitation, an owner included
    assert {:error, %Ash.Error.Forbidden{}} = upd(row, :update, %{}, owner)
    assert {:error, %Ash.Error.Forbidden{}} = upd(row, :accept, %{accepted_at: DateTime.utc_now()}, owner)

    # revoke works while pending (CONTROL) and not after
    {:ok, revoked} = upd(row, :revoke, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, admin)
    assert revoked.status == "revoked"
    assert {:error, _} = upd(Ash.get!(Invitation, inv.id, authorize?: false), :revoke, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, admin)
  end

  test "Org: a slug is refused when it matches another organization's slug (trimmed, ignoring case) or id" do
    assert described("ido_org", "slug") =~ "refuse a non-empty slug that matches another organization's slug (trimmed, ignoring case) or id"

    slug = "b1-slug-#{n()}"
    first = mk_org(slug)
    other = mk_org("b1-other-#{n()}")

    create = fn slug -> Org |> Ash.Changeset.for_create(:create, %{name: "x", slug: slug}) |> Ash.create(authorize?: false) end

    for taken <- [slug, String.upcase(slug), "  #{slug} ", first.id] do
      assert {:error, %Ash.Error.Invalid{}} = create.(taken)
    end

    assert {:ok, _} = create.("b1-fresh-#{n()}")

    # update: another org's slug is refused, the org's own slug re-sent is not
    admin = %{org_id: other.id, role: :admin, plane: :tenant, kind: :tenant, id: "a"}
    assert {:error, %Ash.Error.Invalid{} = refused} = upd(other, :update, %{slug: String.upcase(slug)}, admin)
    assert Exception.message(refused) =~ ~r/slug/i
    assert {:ok, _} = upd(other, :update, %{slug: other.slug}, admin)
  end

  test "User vault fields: the actor's plane decides whether a read gets plain text, an omission or a mask" do
    full = described("usr_user", "full_name")
    assert full =~ "A tenant-plane actor reads it in clear"
    assert full =~ "an operator only under a reveal grant (else omitted; masked while impersonating)"
    assert full =~ "a plane-less actor masked"
    assert full =~ "AI egress masks it; only a completion call can carry it in clear"

    org = mk_org()
    subject = mk_user(org, %{full_name: %{first: "Plain", last: "Reader"}, emails: ["plain@example.test"]})
    base = %{id: "reader", org_id: org.id, role: :admin, kind: :tenant}

    read = fn actor ->
      User
      |> Ash.Query.filter(id == ^subject.id)
      |> Ash.Query.ensure_selected([:full_name, :emails])
      |> Ash.read_one!(actor: actor)
    end

    prev = Application.get_env(:samen_core, :reveal_grant)
    Application.delete_env(:samen_core, :reveal_grant)
    on_exit(fn -> if prev, do: Application.put_env(:samen_core, :reveal_grant, prev), else: Application.delete_env(:samen_core, :reveal_grant) end)

    # tenant plane: clear
    refute match?(%Samen.Masked{}, read.(Map.put(base, :plane, :tenant)).full_name)
    assert inspect(read.(Map.put(base, :plane, :tenant)).full_name) =~ "Plain"

    # operator without a grant: omitted; impersonating operator: masked (present); plane-less: masked
    assert %Ash.ForbiddenField{} = read.(Map.put(base, :plane, :operator)).full_name
    assert %Samen.Masked{} = read.(Map.merge(base, %{plane: :operator, impersonation: %{session_id: "s"}})).full_name
    assert %Samen.Masked{} = read.(base).full_name

    # operator WITH a reveal grant (positive control for the omission above): clear
    Application.put_env(:samen_core, :reveal_grant, ApproveAll)
    granted = read.(Map.put(base, :plane, :operator))
    refute match?(%Ash.ForbiddenField{}, granted.full_name)
    refute match?(%Samen.Masked{}, granted.full_name)
    assert inspect(granted.full_name) =~ "Plain"
  end
end
