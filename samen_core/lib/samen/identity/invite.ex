defmodule Samen.Identity.Invite do
  @moduledoc """
  A5 — team invitations (ADR-035 §5 A5; spec §WS-A A5). Invite-by-email with
  role selection on the EXISTING `Identity.Invitation` resource, hardened
  (T05) to `token_digest`/`email_bidx` (§4.2/§4.1) with the 4-state lifecycle
  `pending -> accepted | revoked | expired`.

  `create/3` runs through the resource's REAL actor-gated `:create` action
  (OrgScope + Verified + the rank-ceiling `RoleAtLeast(:admin)`/`ManageRole`
  pair, `Samen.Scopes.Identity.Blueprint.define_invitation/5`) so the
  inviter's authority is checked for real — a non-admin, or an admin inviting
  above their own rank, is refused before any row exists.

  `accept/3` is a two-step, TOCTOU-safe flow:

    1. `preview/2` — a plain (non-mutating) read: is the token pending and
       unexpired? Does a `Credential` already exist for the invited email
       (`email_bidx` match — ADR-035 §4.1's "invite-matching", never a vault
       reveal)? This decides whether the caller needs to collect a password.
    2. the real `accept/3` — the ONE atomic single-use/expiring transition
       (the `Samen.Auth.TokenConsume` discipline, hand-rolled here because
       the token lives ON the Invitation row, not a shared `AuthToken` —
       ADR-035 §4.2's invite-context row), THEN lands the invitee's
       `User`+`Membership` at the invited role in the INVITING org (never an
       actor-supplied org — the org is always the token-matched row's own
       `org_id`, so there is no cross-org forgery surface). An existing
       credential joins directly; a brand-new invitee (no prior signup)
       supplies a password and gets a freshly minted, PRE-VERIFIED credential
       (token possession IS the email-ownership proof — ADR-035 §5 A5).

  `revoke/3` is the admin-gated `pending -> revoked` cancel, org-scoped via
  `scope:` (the SAME read that lands `{:error, :not_found}` for a
  cross-org/foreign invitation id — no existence oracle across orgs).
  """

  alias Samen.Auth.Hasher
  alias Samen.Auth.PasswordPolicy
  alias Samen.Auth.TokenMint
  alias Samen.Delivery.AuthMailer
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify

  require Ash.Query
  require Logger

  @invite_ttl_seconds 14 * 24 * 60 * 60

  @type mods :: %{
          required(:invitation) => module(),
          required(:credential) => module(),
          required(:user) => module(),
          required(:membership) => module(),
          required(:repo) => module()
        }

  # ---------------------------------------------------------------------------
  # Create — invite-by-email with role selection.
  # ---------------------------------------------------------------------------

  @doc """
  Invite `attrs[:email]` into `scope`'s org at `attrs[:role]` (default
  `:member`). `scope` is the INVITER's actor scope — the `Invitation.:create`
  policy (OrgScope + Verified + RoleAtLeast(:admin) + ManageRole) runs for
  REAL under it. Returns `{:ok, invitation, raw_token}` (the raw token is
  handed back ONCE — never persisted; embedded in the invite email
  `AuthMailer` dispatches through the fail-honest Delivery chokepoint) or
  `{:error, reason}` — either a policy refusal or a blocked/failed send.
  """
  @spec create(mods(), Samen.Scope.t() | map(), map()) ::
          {:ok, term(), String.t()} | {:error, term()}
  def create(%{} = mods, scope, %{} = attrs) do
    email = Map.fetch!(attrs, :email)

    with {:ok, bidx} <- Samen.Auth.BlindIndex.compute(email) do
      raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      expires_at =
        DateTime.utc_now() |> DateTime.add(@invite_ttl_seconds, :second) |> DateTime.truncate(:second)

      create_attrs = %{
        org_id: scope_org_id(scope),
        role: Map.get(attrs, :role, :member),
        email: [email]
      }

      mods.invitation
      |> Ash.Changeset.for_create(:create, create_attrs, scope: scope)
      |> Ash.Changeset.force_change_attribute(:status, "pending")
      |> Ash.Changeset.force_change_attribute(:token_digest, TokenMint.digest(raw_token))
      |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
      |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      |> Ash.create(scope: scope)
      |> case do
        {:ok, invitation} ->
          Audit.auth_event(mods.repo,
            event: "invite_sent",
            subject_id: invitation.id,
            actor_id: actor_id(scope)
          )

          # Pass the KNOWN, already-resolved org_id (the SAME value written to
          # `create_attrs[:org_id]`), NOT `invitation.org_id` — a core column
          # (`Samen.Transformers.CoreAttributes`) that is `%Ash.NotLoaded{}` on
          # the freshly-created struct and would crash `String.Chars` in the
          # delivery log line (F2/T111).
          dispatch(invitation, raw_token, scope_org_id(scope))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp dispatch(invitation, raw_token, org_id) do
    case AuthMailer.dispatch(:invite,
           invitation_id: invitation.id,
           org_id: org_id,
           raw_token: raw_token
         ) do
      {:ok, _receipt} -> {:ok, invitation, raw_token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      # An already-persisted invitation row must not orphan the caller in an
      # unhandled crash — BUT a dispatch failure is a FAILURE, never faked to
      # success. ADR-014's fail-honest invariant ("never returns `{:ok, _}` for
      # work it did not do"), applied caller-side: surface an honest
      # `{:error, _}`, logged — NEVER `{:ok, invitation, raw_token}` (F2/T111).
      Logger.error(
        "[Invite] invite email dispatch RAISED for invitation_id=#{invitation.id}: " <>
          Exception.message(e)
      )

      {:error, {:dispatch_crashed, Exception.message(e)}}
  end

  # ---------------------------------------------------------------------------
  # Preview — non-mutating: is this token good, and does the invitee already
  # have an account?
  # ---------------------------------------------------------------------------

  @doc """
  Non-mutating check of a raw invite token: `{:ok, %{invitation:,
  needs_registration?:}}` when `pending` and unexpired, else `{:error,
  :expired | :revoked | :already_accepted | :invalid_token}`. Never consumes
  the token — `accept/3` does that atomically.
  """
  @spec preview(mods(), String.t()) ::
          {:ok, %{invitation: term(), needs_registration?: boolean()}}
          | {:error, :expired | :revoked | :already_accepted | :invalid_token}
  def preview(%{} = mods, raw_token) when is_binary(raw_token) do
    digest = TokenMint.digest(raw_token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case find_by_digest(mods.invitation, digest) do
      [%{status: "pending", expires_at: expires_at} = invitation] ->
        if expires_at && DateTime.compare(expires_at, now) == :gt do
          {:ok,
           %{invitation: invitation, needs_registration?: find_credential(mods, invitation.email_bidx) == []}}
        else
          {:error, :expired}
        end

      [%{status: "revoked"}] ->
        {:error, :revoked}

      [%{status: "accepted"}] ->
        {:error, :already_accepted}

      [%{status: "expired"}] ->
        {:error, :expired}

      _ ->
        {:error, :invalid_token}
    end
  end

  # ---------------------------------------------------------------------------
  # Accept — the atomic single-use transition + landing the Role/Membership.
  # ---------------------------------------------------------------------------

  @doc """
  Accept a raw invite token. `opts[:password]` is REQUIRED only when
  `preview/2` reported `needs_registration?: true` (no existing `Credential`
  for the invited email) — it mints a fresh, PRE-VERIFIED credential (token
  possession is the email-ownership proof). Returns `{:ok, %{status: :joined,
  org_id:, credential:, user:, membership:}}` or `{:error, reason}` —
  `:password_required`, `:weak_password`, or one of `preview/2`'s terminal
  errors (a race between `preview/2` and this call still resolves correctly:
  the atomic transition below is the REAL single-use guarantee, not the
  preview read).
  """
  @spec accept(mods(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def accept(%{} = mods, raw_token, opts \\ []) when is_binary(raw_token) do
    password = Keyword.get(opts, :password)

    case preview(mods, raw_token) do
      {:ok, %{needs_registration?: true}} when is_nil(password) ->
        {:error, :password_required}

      {:ok, %{needs_registration?: true}} ->
        with :ok <- PasswordPolicy.validate(password) do
          do_accept(mods, raw_token, password)
        end

      {:ok, %{needs_registration?: false}} ->
        do_accept(mods, raw_token, nil)

      {:error, _reason} ->
        # `preview/2`'s classification is a non-mutating pre-check. For an
        # expired token specifically, the REAL transition (`do_accept`) is
        # what performs the lazy `pending -> expired` PERSIST (`attempt_expire`)
        # — calling it here (rather than returning `preview`'s error verbatim)
        # is what makes `expired` a REACHED row state, not merely inferred.
        # `do_accept` independently re-derives the SAME terminal classification
        # for revoked/accepted/invalid — redundant but harmless.
        do_accept(mods, raw_token, nil)
    end
  end

  defp do_accept(mods, raw_token, password) do
    digest = TokenMint.digest(raw_token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case attempt_accept(mods, digest, now) do
      {:ok, invitation} ->
        land_membership(mods, invitation, password)

      :no_match ->
        handle_no_match(mods, digest, now)
    end
  end

  defp handle_no_match(mods, digest, now) do
    case attempt_expire(mods, digest, now) do
      {:ok, _expired} -> {:error, :expired}
      :no_match -> classify_terminal(mods.invitation, digest)
    end
  end

  defp classify_terminal(invitation_mod, digest) do
    case find_by_digest(invitation_mod, digest) do
      [%{status: "revoked"}] -> {:error, :revoked}
      [%{status: "accepted"}] -> {:error, :already_accepted}
      [%{status: "expired"}] -> {:error, :expired}
      _ -> {:error, :invalid_token}
    end
  end

  # The single-use transition guard, WITHOUT relying on Ash's atomic-bulk-
  # update codepath: `Identity.Invitation` carries a vaulted `email`, so
  # EVERY create/update action (including `:accept`/`:expire`, which never
  # touch `:email`) inherits the resource-wide `Samen.Pii.WriteGuard`/
  # `Samen.Vault.Change` pair (`MaterializePii`, unscoped by action) — the DSL
  # verifier cannot prove those atomic-SQL-compatible, so `:accept`/`:expire`
  # are `require_atomic? false` (see the blueprint). The SAME guarantee a
  # single `UPDATE ... WHERE status = 'pending' ... RETURNING` gives is
  # instead built from Postgres row-locking (`SELECT ... FOR UPDATE`) inside
  # an explicit transaction (the `Samen.AuditChain.tip_locked/2` precedent):
  # a concurrent second caller's own `SELECT ... FOR UPDATE` on the SAME row
  # BLOCKS until this transaction commits, then re-evaluates the `status ==
  # "pending"` filter against the now-updated row and matches ZERO rows —
  # the single-use property holds under concurrency, not just sequential
  # replay.
  defp attempt_accept(mods, digest, now) do
    transition(mods, digest, fn -> locked_pending(mods.invitation, digest, now) end, :accept, %{accepted_at: now})
  end

  defp attempt_expire(mods, digest, now) do
    transition(mods, digest, fn -> locked_pending_expired(mods.invitation, digest, now) end, :expire, %{})
  end

  defp transition(mods, _digest, locked_fetch, action, action_attrs) do
    mods.repo.transaction(fn ->
      case locked_fetch.() do
        [invitation | _] ->
          invitation
          |> Ash.Changeset.for_update(action, action_attrs, authorize?: false)
          # `Ash.update/2` returns a struct scoped to the CHANGESET's own
          # select, not the pre-update query's `ensure_selected` — explicitly
          # re-select the fields `land_membership/3`/`classify_terminal/2`
          # read on the result (`org_id`/`role`/`email_bidx` are otherwise
          # `#Ash.NotLoaded{}` on the returned struct).
          |> Ash.Changeset.select([:id, :org_id, :role, :status, :email_bidx, :expires_at, :accepted_at, :revoked_at])
          |> Ash.update()
          |> case do
            {:ok, updated} -> updated
            {:error, reason} -> mods.repo.rollback(reason)
          end

        [] ->
          mods.repo.rollback(:no_match)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, :no_match} -> :no_match
      {:error, _reason} -> :no_match
    end
  end

  defp locked_pending(invitation_mod, digest, now) do
    invitation_mod
    |> Ash.Query.filter(token_digest == ^digest and status == "pending" and expires_at > ^now)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.ensure_selected([:id, :org_id, :role, :status, :email_bidx])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth invite-accept lookup keyed on the unique token digest
    # (<=1 row, FOR UPDATE); the org comes FROM the invitation row
    |> Ash.read!(authorize?: false)
  end

  defp locked_pending_expired(invitation_mod, digest, now) do
    invitation_mod
    |> Ash.Query.filter(token_digest == ^digest and status == "pending" and expires_at <= ^now)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.ensure_selected([:id, :org_id, :role, :status, :email_bidx])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth invite-accept lookup keyed on the unique token digest
    # (<=1 row, FOR UPDATE); the org comes FROM the invitation row
    |> Ash.read!(authorize?: false)
  end

  defp find_by_digest(invitation_mod, digest) do
    invitation_mod
    |> Ash.Query.filter(token_digest == ^digest)
    |> Ash.Query.ensure_selected([:id, :org_id, :role, :status, :expires_at, :email_bidx])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth invite-accept lookup keyed on the unique token digest (<=1 row);
    # the org comes FROM the invitation row, never from the request
    |> Ash.read!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Landing the Role/Membership (and, when needed, a fresh Credential).
  # ---------------------------------------------------------------------------

  defp land_membership(mods, invitation, password) do
    case find_credential(mods, invitation.email_bidx) do
      [credential] ->
        finish_join(mods, invitation, credential)

      [] ->
        case create_credential_for_invite(mods, invitation, password) do
          {:ok, credential} -> finish_join(mods, invitation, credential)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp find_credential(mods, bidx) do
    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    |> Ash.Query.ensure_selected([:id, :verified_at])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth boot-path credential lookup keyed on the unique email blind index (<=1 row)
    |> Ash.read!(authorize?: false)
  end

  defp create_credential_for_invite(_mods, _invitation, nil), do: {:error, :password_required}

  defp create_credential_for_invite(mods, invitation, password) do
    {hash, scheme} = Hasher.hash(password)

    mods.credential
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:email_bidx, invitation.email_bidx)
    |> Ash.Changeset.force_change_attribute(:password_hash, hash)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
    # Token possession IS the email-ownership proof (ADR-035 §5 A5) — the
    # invite-minted credential is pre-verified, no separate email_verify loop.
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Ash.create()
  end

  defp finish_join(mods, invitation, credential) do
    case find_user(mods, credential.id, invitation.org_id) do
      [user] ->
        membership = ensure_membership(mods, user, invitation)
        audit_accept(mods, invitation, credential)
        notify_accept(mods, invitation, user)
        {:ok, joined(invitation, credential, user, membership)}

      [] ->
        {:ok, user} = create_user_for_invite(mods, invitation, credential)
        membership = create_membership(mods, invitation.org_id, user.id, invitation.role)
        audit_accept(mods, invitation, credential)
        notify_accept(mods, invitation, user)
        {:ok, joined(invitation, credential, user, membership)}
    end
  end

  # ADR-035 §5 A10 (T09) — `auth.invite_accepted`'s notify half. The ADR names
  # TWO recipients ("inviter (accepted); org admins (accepted)"); ONLY "org
  # admins" is resolvable here — `Identity.Invitation` stores no "invited_by"
  # reference (would need a new column + a 3-host mirror migration, out of
  # this task's scope), so the literal "inviter" recipient is not addressable.
  # "Org admins" (role >= :admin, the SAME rank `RoleAtLeast(:admin)` gates
  # `create/3` with) ARE resolvable via the existing `mods.membership` — every
  # admin/owner in the invitation's org gets the security notice. Best-effort
  # (`Notify.security_notice/4` never raises); the invitee's email never
  # appears in the body (token-blind — INV-1).
  defp notify_accept(mods, invitation, user) do
    mods.membership
    |> Ash.Query.filter(org_id == ^invitation.org_id and role in [:owner, :admin])
    |> Ash.Query.ensure_selected([:id, :user_id])
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn membership ->
      Notify.security_notice(
        invitation.org_id,
        membership.user_id,
        "invite_accepted",
        "A new team member accepted their invitation and joined your org.",
        %{"user_id" => user.id}
      )
    end)
  rescue
    _ -> :ok
  end

  defp joined(invitation, credential, user, membership) do
    %{status: :joined, org_id: invitation.org_id, credential: credential, user: user, membership: membership}
  end

  defp find_user(mods, credential_id, org_id) do
    mods.user
    |> Ash.Query.filter(credential_id == ^credential_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :org_id, :credential_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp find_membership(mods, user_id, org_id) do
    mods.membership
    |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id)
    |> Ash.Query.ensure_selected([:id, :role, :org_id, :user_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp ensure_membership(mods, user, invitation) do
    case find_membership(mods, user.id, invitation.org_id) do
      [membership] -> membership
      [] -> create_membership(mods, invitation.org_id, user.id, invitation.role)
    end
  end

  # The invitee's OWN email, resolved through the SAME tenant-plane
  # PiiResolution seam every own-org read uses (the "tenant-as-owner rule" —
  # no operator reveal grant needed, this is a plain plane-scoped read of the
  # invitation's own org). Best-effort: a resolver hiccup leaves the new
  # User's emails empty rather than blocking the join (the credential/
  # membership landing is what MUST succeed).
  #
  # A revealed composite vault value arrives as its JSON-serialized plaintext
  # (the ProfileLive `decode_composite/1` posture) — `decode_email/1` handles
  # every shape `create/3`'s `email: [email_string]` write can round-trip as.
  defp reveal_invitation_email(mods, invitation) do
    actor = %{
      id: "invite:#{invitation.id}",
      org_id: invitation.org_id,
      role: :member,
      kind: :tenant,
      plane: :tenant
    }

    case Samen.Api.PiiResolution.resolve([invitation], mods.invitation, actor, repo: mods.repo) do
      [%{email: value}] -> decode_email(value)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_email(<<c, _::binary>> = json) when c in [?{, ?[] do
    case Jason.decode(json) do
      {:ok, [address | _]} when is_binary(address) -> {:ok, address}
      {:ok, [%{"address" => address} | _]} when is_binary(address) -> {:ok, address}
      {:ok, %{"entries" => [%{"address" => address} | _]}} when is_binary(address) -> {:ok, address}
      _ -> :error
    end
  end

  defp decode_email(%Samen.Type.Emails{entries: [%{address: address} | _]}) when is_binary(address),
    do: {:ok, address}

  defp decode_email(_), do: :error

  defp create_user_for_invite(mods, invitation, credential) do
    emails =
      case reveal_invitation_email(mods, invitation) do
        {:ok, address} -> [%{label: "primary", address: address}]
        :error -> []
      end

    mods.user
    |> Ash.Changeset.for_create(:create, %{org_id: invitation.org_id, emails: emails}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
    |> Ash.create()
  end

  defp create_membership(mods, org_id, user_id, role) do
    mods.membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user_id, role: role}, authorize?: false)
    # `Ash.create!/2` does not load `:org_id` by default on the returned
    # struct (a CoreAttributes-injected column) — callers (`joined/4`'s
    # `membership.org_id` assertion) need it loaded.
    |> Ash.Changeset.select([:id, :org_id, :role, :status, :user_id])
    |> Ash.create!()
  end

  defp audit_accept(mods, invitation, credential) do
    Audit.auth_event(mods.repo,
      event: "invite_accepted",
      subject_id: invitation.id,
      actor_id: credential.id
    )
  end

  # ---------------------------------------------------------------------------
  # Revoke — admin-gated pending -> revoked cancel.
  # ---------------------------------------------------------------------------

  @doc """
  Revoke a PENDING invitation. `scope` is the REVOKER's actor scope (admin+,
  org-scoped — `Invitation.:revoke`'s policy). `{:ok, invitation}`,
  `{:error, :not_found}` (unknown id, cross-org id, or not `pending` — one
  outcome, no existence oracle), or a policy `{:error, reason}`.
  """
  @spec revoke(mods(), Samen.Scope.t() | map(), String.t()) :: {:ok, term()} | {:error, term()}
  def revoke(%{} = mods, scope, invitation_id) when is_binary(invitation_id) do
    with [invitation | _] <- find_pending_for_scope(mods, scope, invitation_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      invitation
      |> Ash.Changeset.for_update(:revoke, %{revoked_at: now}, scope: scope)
      |> Ash.update(scope: scope)
      |> case do
        {:ok, updated} ->
          Audit.auth_event(mods.repo,
            event: "invite_revoked",
            subject_id: updated.id,
            actor_id: actor_id(scope)
          )

          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  defp find_pending_for_scope(mods, scope, invitation_id) do
    mods.invitation
    |> Ash.Query.filter(id == ^invitation_id and status == "pending")
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
  end

  # ---------------------------------------------------------------------------
  # Scope helpers.
  # ---------------------------------------------------------------------------

  defp actor_id(%Samen.Scope{actor: %{id: id}}), do: id
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp scope_org_id(%{org_id: org_id}), do: org_id
  defp scope_org_id(_), do: nil
end
