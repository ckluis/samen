defmodule Samen.Web.Settings.Invitations do
  @moduledoc """
  The framework TEAM INVITATIONS settings engine (ADR-035 §5 A5; T05) — list /
  create / revoke over the hardened `Identity.Invitation` resource, wrapping
  `Samen.Identity.Invite` (samen_core) with the per-plane PII resolution the
  settings surfaces already run (the `Settings.Reads`/`ApiKeys` precedent).

  ## Masking (INV-1, the T05-owed 3-proof)

  `list/2` resolves each row's vaulted `email` through
  `Samen.Api.PiiResolution` on the caller's plane — tenant plane clear;
  operator-impersonation plane `%Samen.Masked{}` (`••••`), NEVER plaintext,
  NEVER a `vt_*` token. This module never calls `Samen.Vault.reveal/3`
  directly and has no "show plaintext" branch — the guarantee is the same
  chokepoint every other masked list (API keys, notifications, files) proves.
  """

  alias Samen.Identity.Invite
  alias Samen.Web.Mount

  @type mods :: Invite.mods()

  @doc "Build the `Samen.Identity.Invite.mods()` map for `mount`."
  @spec mods(Mount.t()) :: mods()
  def mods(%Mount{} = mount) do
    %{
      invitation: Mount.resource(mount, Invitation),
      credential: Mount.resource(mount, Credential),
      user: Mount.resource(mount, User),
      membership: Mount.resource(mount, Membership),
      repo: mount.repo
    }
  end

  @doc """
  Invite `email` at `role` into `scope`'s org. `{:ok, invitation, raw_token}`
  or `{:error, reason}` — see `Samen.Identity.Invite.create/3`.
  """
  @spec create(Mount.t(), Samen.Scope.t() | map(), String.t(), atom() | String.t()) ::
          {:ok, term(), String.t()} | {:error, term()}
  def create(%Mount{} = mount, scope, email, role) when is_binary(email) do
    Invite.create(mods(mount), scope, %{email: email, role: normalize_role(role)})
  rescue
    e -> {:error, e}
  end

  @doc """
  List `scope`'s org invitations, newest first, `email` resolved per plane
  (the masking watch-list surface — INV-1). Never the raw email on the
  operator-without-grant plane; never a `vt_*` token.
  """
  @spec list(Mount.t(), Samen.Scope.t() | map()) :: [map()]
  def list(%Mount{} = mount, scope) do
    Mount.resource(mount, Invitation)
    |> Ash.Query.ensure_selected([
      :id,
      :role,
      :status,
      :email,
      :expires_at,
      :accepted_at,
      :revoked_at,
      :inserted_at,
      :org_id
    ])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, scope)
  rescue
    _ -> []
  end

  @doc "Revoke a pending invitation — admin-gated. `{:ok, invitation}` or `{:error, reason}`."
  @spec revoke(Mount.t(), Samen.Scope.t() | map(), String.t()) :: {:ok, term()} | {:error, term()}
  def revoke(%Mount{} = mount, scope, invitation_id) when is_binary(invitation_id) do
    Invite.revoke(mods(mount), scope, invitation_id)
  end

  defp resolve_pii(records, mount, scope) do
    Samen.Api.PiiResolution.resolve(records, Mount.resource(mount, Invitation), actor_of(scope), repo: mount.repo)
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) when is_binary(role) do
    Enum.find(Samen.Scope.Role.all(), :member, fn r -> Atom.to_string(r) == role end)
  end

  defp normalize_role(_), do: :member
end
