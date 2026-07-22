defmodule Samen.Web.Auth.InvitationTest do
  @moduledoc """
  T05 — A5 team invitations (ADR-035 §5 A5), against the samen_web test
  host's Operator Identity mount. Proves:

    1. The 4-state lifecycle (`pending -> accepted | revoked | expired`) —
       every state is REACHED (the `status` column, not merely inferred);
       terminal states are enforced (accepting a revoked/expired invite
       fails); a fresh pending invite's accept succeeds — the positive
       control.
    2. Accept lands a `Membership` at the invited ROLE in the INVITING org
       (assert); the invitee's OWN, separately-registered org is untouched
       — the invite never crosses org boundaries (cross-org red test).
    3. INV-1: the invitee `email` on the invitations LIST surface resolves
       per plane (MaskingCase 3-proof) — tenant clear, operator `••••`,
       never a `vt_*` token.
    4. (T04-verdict binding addendum) After accept, the invitee's credential
       resolves to a per-org ACTOR through the `CurrentOrg` seam — RED: a
       credential with NO membership in org X cannot resolve an actor there
       (`Samen.Web.CurrentOrg.resolve_actor/3` + the `:authn`/
       `:authorized_orgs` `resolve/3` prod-path fallback); POSITIVE CONTROL:
       the accepted invitee's credential CAN.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Auth.SessionCreate
  alias Samen.Auth.TokenMint
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.Invitations
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.Session
  alias Samen.WebTest.Operator.User

  # See confirm_test.exs/reset_test.exs/session_test.exs — `Samen.Delivery.AuthMailer`
  # resolves its env the SAME way `Samen.Delivery.Lifecycle.EmailWorker` does; the
  # house convention is to set it explicitly (samen_core is a path dep of multiple
  # sibling hosts, where the compiled-in fallback doesn't reliably resolve to :test).
  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp invite_mods,
    do: %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Repo}

  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}
  defp session_mods, do: %{session: Session}

  defp unique_email, do: "invite-#{System.unique_integer([:positive])}@example.test"

  defp register!(email \\ nil) do
    attrs = %{
      org_name: "Invite Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: email || unique_email(),
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result |> Map.put(:email, attrs.email)
  end

  defp owner_scope(result), do: tenant_actor_scope(result, :owner)
  defp admin_scope(result), do: tenant_actor_scope(result, :admin)

  defp tenant_actor_scope(result, role) do
    %Samen.Scope{
      actor: %{id: result.user.id, org_id: result.org.id, role: role, verified?: true, kind: :tenant, plane: :tenant}
    }
  end

  defp force_expire!(invitation_id, expires_at) do
    Invitation
    |> Ash.get!(invitation_id, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
    |> Ash.update!()
  end

  defp reread_invitation(id) do
    Invitation
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :status, :role, :org_id, :expires_at, :accepted_at, :revoked_at, :email_bidx])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ===========================================================================
  # 1. Invite.create/3 — role-selection + the inviter's-rank ceiling
  # ===========================================================================

  describe "Samen.Identity.Invite.create/3" do
    test "an owner can invite a teammate at a bounded role; a pending row + raw token are returned" do
      inviter = register!()
      email = unique_email()

      assert {:ok, invitation, raw_token} =
               Invite.create(invite_mods(), owner_scope(inviter), %{email: email, role: :member})

      assert invitation.status == "pending"
      assert invitation.role == :member
      assert is_binary(raw_token)
      refute invitation.token_digest == raw_token
      refute invitation.token_digest =~ raw_token
      assert invitation.token_digest == TokenMint.digest(raw_token)
      refute is_nil(invitation.expires_at)
    end

    test "RED: an admin cannot invite above their own rank (no invite above your own rank)" do
      inviter = register!()

      assert {:error, _} = Invite.create(invite_mods(), admin_scope(inviter), %{email: unique_email(), role: :owner})
    end

    test "POSITIVE CONTROL: an owner CAN invite an admin (the rank ceiling is not a blanket deny)" do
      inviter = register!()

      assert {:ok, _invitation, _raw} =
               Invite.create(invite_mods(), owner_scope(inviter), %{email: unique_email(), role: :admin})
    end
  end

  # ===========================================================================
  # 2. The 4-state lifecycle: pending -> accepted | revoked | expired
  # ===========================================================================

  describe "the 4-state lifecycle" do
    test "PENDING -> ACCEPTED: an existing credential's accept lands a Membership at the invited role in the INVITING org (POSITIVE CONTROL)" do
      inviter = register!()
      invitee = register!()

      {:ok, invitation, raw_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email, role: :admin})

      assert {:ok, joined} = Invite.accept(invite_mods(), raw_token)
      assert joined.status == :joined
      assert joined.org_id == inviter.org.id
      assert joined.membership.role == :admin
      assert joined.membership.org_id == inviter.org.id
      assert joined.user.credential_id == invitee.credential.id

      row = reread_invitation(invitation.id)
      assert row.status == "accepted"
      refute is_nil(row.accepted_at)
    end

    test "RED: accepting an already-ACCEPTED invite fails — terminal, no double-join" do
      inviter = register!()
      invitee = register!()
      {:ok, _invitation, raw_token} = Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email})

      assert {:ok, _} = Invite.accept(invite_mods(), raw_token)
      assert {:error, :already_accepted} = Invite.accept(invite_mods(), raw_token)
    end

    test "PENDING -> REVOKED: an admin can revoke a pending invite; accepting it after fails (RED); a sibling pending invite still accepts (CONTROL)" do
      inviter = register!()
      invitee = register!()
      other_invitee = register!()

      {:ok, revoked_invitation, revoked_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email})

      {:ok, _live_invitation, live_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: other_invitee.email})

      assert {:ok, _revoked} = Invite.revoke(invite_mods(), owner_scope(inviter), revoked_invitation.id)
      assert reread_invitation(revoked_invitation.id).status == "revoked"

      # RED — a revoked invite can never be accepted.
      assert {:error, :revoked} = Invite.accept(invite_mods(), revoked_token)

      # CONTROL — a sibling still-pending invite is entirely unaffected.
      assert {:ok, joined} = Invite.accept(invite_mods(), live_token)
      assert joined.status == :joined
    end

    test "RED: revoke refuses a NON-pending invitation (already accepted) — illegal transition" do
      inviter = register!()
      invitee = register!()
      {:ok, invitation, raw_token} = Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email})

      assert {:ok, _} = Invite.accept(invite_mods(), raw_token)
      assert {:error, :not_found} = Invite.revoke(invite_mods(), owner_scope(inviter), invitation.id)
      # The row stays "accepted" — the illegal accepted -> revoked transition never happened.
      assert reread_invitation(invitation.id).status == "accepted"
    end

    test "PENDING -> EXPIRED: an accept attempt past expiry lazily transitions the row and is refused (RED); a fresh pending invite still accepts (CONTROL)" do
      inviter = register!()
      invitee = register!()
      other_invitee = register!()

      {:ok, expiring_invitation, expired_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email})

      {:ok, _fresh_invitation, fresh_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: other_invitee.email})

      force_expire!(expiring_invitation.id, DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second))

      # RED — the row is lazily transitioned to "expired" (a REACHED state, not an
      # inference) and the accept is refused.
      assert {:error, :expired} = Invite.accept(invite_mods(), expired_token)
      assert reread_invitation(expiring_invitation.id).status == "expired"

      # A second attempt on the now-terminal row is the SAME outcome (idempotent refusal).
      assert {:error, :expired} = Invite.accept(invite_mods(), expired_token)

      # CONTROL — an unexpired sibling still accepts fine.
      assert {:ok, joined} = Invite.accept(invite_mods(), fresh_token)
      assert joined.status == :joined
    end

    test "RED: an unknown/garbage token is refused generically" do
      assert {:error, :invalid_token} = Invite.accept(invite_mods(), "totally-unknown-token")
    end
  end

  # ===========================================================================
  # 3. Accept is org-scoped BY CONSTRUCTION — cross-org red test
  # ===========================================================================

  describe "accept lands the Membership ONLY in the inviting org — cross-org red test" do
    test "the invitee's OWN separately-registered org is untouched by accepting a DIFFERENT org's invite" do
      inviter = register!()
      invitee = register!()

      {:ok, _invitation, raw_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email, role: :member})

      assert {:ok, joined} = Invite.accept(invite_mods(), raw_token)

      # The NEW membership lands in the INVITING org...
      assert joined.org_id == inviter.org.id
      assert joined.credential.id == invitee.credential.id

      # ...and the invitee's OWN org (from their own registration) is untouched:
      # the SAME credential now holds TWO memberships, each correctly org-scoped.
      memberships =
        Membership
        |> Ash.Query.filter(user_id == ^invitee.user.id or user_id == ^joined.user.id)
        |> Ash.Query.select([:id, :org_id, :role, :user_id])
        |> Ash.read!(authorize?: false)

      own_org_membership = Enum.find(memberships, &(&1.org_id == invitee.org.id))
      inviting_org_membership = Enum.find(memberships, &(&1.org_id == inviter.org.id))

      refute is_nil(own_org_membership)
      refute is_nil(inviting_org_membership)
      assert own_org_membership.role == :owner
      assert inviting_org_membership.role == :member
      refute own_org_membership.org_id == inviting_org_membership.org_id
    end
  end

  # ===========================================================================
  # 4. INV-1 — the invitee email on the invitations LIST surface: MaskingCase 3-proof
  # ===========================================================================

  describe "INV-1: invitee email on the invitations list surface" do
    setup do
      inviter = register!()
      email = unique_email()
      {:ok, _invitation, _raw} = Invite.create(invite_mods(), owner_scope(inviter), %{email: email, role: :member})
      %{inviter: inviter, email: email}
    end

    test "GREEN: the tenant plane resolves the invitee email CLEAR", %{inviter: inviter, email: email} do
      mount = build_mount(:settings)
      scope = Plane.scope(Plane.tenant(), inviter.org.id)

      [listed] = Invitations.list(mount, scope)
      refute match?(%Samen.Masked{}, listed.email)
      assert inspect(listed.email) =~ email
      refute inspect(listed.email) =~ "vt_"
    end

    test "RED: the operator-without-grant plane masks the invitee email — ••••, never plaintext, never vt_*",
         %{inviter: inviter, email: email} do
      plane = Plane.operator("op-1", inviter.org.id, "invite-mask-session")
      mount = Mount.new(:settings, Samen.WebTest.Operator, Repo, plane: plane)
      scope = Plane.scope(plane, inviter.org.id)

      [listed] = Invitations.list(mount, scope)
      assert_plane_masked!(listed.email)
      refute to_string(listed.email) =~ email
    end

    test "ANTI-TAUTOLOGY: the SAME row is clear on tenant ∧ masked on operator — the plane is the gate",
         %{inviter: inviter, email: email} do
      tenant_plane = Plane.tenant()
      operator_plane = Plane.operator("op-1", inviter.org.id, "invite-mask-session")

      mount_tenant = Mount.new(:settings, Samen.WebTest.Operator, Repo, plane: tenant_plane)
      mount_operator = Mount.new(:settings, Samen.WebTest.Operator, Repo, plane: operator_plane)

      [tenant_listed] = Invitations.list(mount_tenant, Plane.scope(tenant_plane, inviter.org.id))
      [operator_listed] = Invitations.list(mount_operator, Plane.scope(operator_plane, inviter.org.id))

      refute match?(%Samen.Masked{}, tenant_listed.email)
      assert inspect(tenant_listed.email) =~ email

      assert_plane_masked!(operator_listed.email)
      refute to_string(operator_listed.email) =~ email

      # SABOTAGE-TWIN refutability: the masked scan above is non-vacuous — the SAME
      # record's tenant-plane read genuinely DOES carry the plaintext it protects.
      assert_leak_detected!(inspect(tenant_listed.email), email)
    end
  end

  # ===========================================================================
  # 5. (T04-verdict binding addendum) CurrentOrg seam: credential -> per-org actor
  # ===========================================================================

  describe "after accept, the invitee's credential resolves to a per-org ACTOR through the CurrentOrg seam" do
    defp spine_settings_mount do
      Mount.new(:settings, Samen.WebTest.Operator, Repo,
        plane: Plane.tenant(),
        labels: %{authn: :required}
      )
    end

    test "RED: a credential with NO membership in org X cannot resolve an actor there (Samen.Web.CurrentOrg.resolve_actor/3)" do
      inviter = register!()
      stranger = register!()

      mount = spine_settings_mount()

      assert CurrentOrg.resolve_actor(mount, stranger.credential.id, inviter.org.id) == nil
    end

    test "POSITIVE CONTROL: the accepted invitee's credential resolves to the real per-org actor (role read from the Membership, not hardcoded :member)" do
      inviter = register!()
      invitee = register!()

      {:ok, _invitation, raw_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email, role: :admin})

      assert {:ok, joined} = Invite.accept(invite_mods(), raw_token)

      mount = spine_settings_mount()
      actor = CurrentOrg.resolve_actor(mount, invitee.credential.id, inviter.org.id)

      refute is_nil(actor)
      assert actor.org_id == inviter.org.id
      assert actor.role == :admin
      assert actor.id == joined.user.id
      assert actor.plane == :tenant
    end

    test "end-to-end: CurrentOrg.resolve/3's :authn prod-path resolves the joined org through a REAL spine session (login -> act-in-org)" do
      inviter = register!()
      invitee = register!()

      {:ok, _invitation, raw_token} =
        Invite.create(invite_mods(), owner_scope(inviter), %{email: invitee.email, role: :member})

      assert {:ok, _joined} = Invite.accept(invite_mods(), raw_token)

      {:ok, _session, raw_session_token} = SessionCreate.create(session_create_mods(), invitee.credential.id)

      mount = spine_settings_mount()
      session = %{Auth.session_token_key() => raw_session_token}

      # Sanity: the session token DOES resolve to the invitee's credential (the
      # login half of "login -> act-in-org").
      assert {:ok, %{credential_id: credential_id}} = Auth.resolve_principal(session, session_mods())
      assert credential_id == invitee.credential.id

      # The act-in-org half: CurrentOrg's fail-closed prod path constrains the
      # resolved org to the credential's REAL authorized set (both orgs — the
      # invitee's own registration AND the newly-joined inviting org).
      assert CurrentOrg.resolve(mount, %{"org" => inviter.org.id}, session) == inviter.org.id
      assert CurrentOrg.resolve(mount, %{"org" => invitee.org.id}, session) == invitee.org.id

      # RED (within the SAME flow): an org the credential never joined is refused —
      # falls back to the credential's first authorized org, never the requested one.
      other = register!()
      refute CurrentOrg.resolve(mount, %{"org" => other.org.id}, session) == other.org.id
    end

    test "RED: a live spine session with NO Membership anywhere resolves no org at all" do
      solo = register!()
      # `register!/1` DOES create a membership (the owner row) — simulate a
      # credential with a live session but zero Identity.User rows by minting
      # a session for a freshly-created, unlinked credential directly.
      {:ok, unlinked_credential} =
        Credential
        |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:email_bidx, "unlinked-#{System.unique_integer([:positive])}")
        |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now() |> DateTime.truncate(:second))
        |> Ash.create()

      {:ok, _session, raw_session_token} = SessionCreate.create(session_create_mods(), unlinked_credential.id)

      mount = spine_settings_mount()
      session = %{Auth.session_token_key() => raw_session_token}

      assert CurrentOrg.resolve(mount, %{"org" => solo.org.id}, session) == nil
    end
  end
end
