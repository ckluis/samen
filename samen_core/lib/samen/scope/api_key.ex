defmodule Samen.Scope.ApiKey do
  @moduledoc """
  The api_key authorization model (T3.1; doc §external-surface "two key classes";
  scope table `api_key`).

  ## The load-bearing rule: a key can never out-reach its actor

  From the doc (§external-surface): *"the same Ash policies that gate the UI gate
  the key, so a key can never see more than its actor may."* An api_key is minted
  BY a membership (a user acting in an org) and carries declared scopes
  (`read`/`write` per resource family). Its **effective** authority is the
  intersection of:

    1. its **declared** scopes (what the key was minted to do), and
    2. its **minting membership's** authority (what the actor may do), which is
       bounded by the membership's role rank AND its org.

  So a `member`-minted key with a declared `write` scope on `billing` is still
  denied `write` on billing if `member` cannot write billing — the key inherits the
  actor's ceiling. And a key is ALWAYS org-bound to its minting membership's org: a
  tenant key acts as the tenant over the tenant's own org's data (no reveal grant),
  and can never reach another org (the org-scope policy sees the key's `org_id`).

  ## Two planes (doc §external-surface)

  A key is bound to exactly one of two planes:

    * `:tenant`   — org-bound; acts as the tenant over its own org. Reads its own
      org's PII per RBAC with NO operator reveal grant (the tenant owns its
      customers' PII in clear).
    * `:operator` — the control-plane / cross-tenant class. Masked by default; a
      subject's plaintext renders `••••` unless an operator reveal grant covers it.
      Crosses the reveal seam.

  This module answers the authorization questions; it does not itself store keys
  (that is the `api_key` resource in the Identity scope). It is pure so the policy
  and the red-path tests can call it directly.
  """

  alias Samen.Scope.Role

  @type plane :: :tenant | :operator
  @type action :: :read | :write

  @type key :: %{
          org_id: String.t(),
          plane: plane(),
          # declared scopes: %{resource_family => [:read, :write]}
          scopes: %{optional(atom() | String.t()) => [action()]},
          # the role of the membership that minted this key (the actor ceiling)
          minter_role: atom() | String.t() | nil
        }

  @doc """
  Effective authority: can this key perform `action` on `family` in `org_id`?

  Denies (returns `false`, fail closed) unless ALL hold:

    1. **org match** — the key's `org_id` equals the requested `org_id`. A key can
       never reach another org (the tenant-plane isolation the org-scope policy
       also enforces at the row level).
    2. **declared scope** — the key declares `action` on `family` (or on `:all`).
       A field/family absent from the key's declared scopes is absent from its
       authority (allowlist, not denylist — the same posture as API serialization).
    3. **actor ceiling** — the minting membership's role is high enough for the
       action. `:write` requires the minter be at least `:member`; `:read` requires
       at least `:viewer`. A key cannot out-reach the actor that minted it: a
       `viewer`-minted key is read-only regardless of its declared scopes.

  This is the mechanism behind the `api_key cannot out-reach its actor` red path.
  """
  @spec authorized?(key(), action(), atom() | String.t(), String.t()) :: boolean()
  def authorized?(key, action, family, org_id)
      when action in [:read, :write] and is_binary(org_id) do
    org_match?(key, org_id) and
      declares?(key, action, family) and
      within_actor_ceiling?(key, action)
  end

  def authorized?(_key, _action, _family, _org_id), do: false

  @doc """
  The two-plane masking rule (doc §external-surface). Given a key, does a vaulted
  field render in clear (`:clear`) or masked (`:masked`)?

    * a `:tenant` key over its OWN org → `:clear` (no reveal grant needed — the
      tenant owns its customers' PII);
    * an `:operator` key → `:masked` unless a grant covers the subject (the reveal
      seam is operator-scoped). This function returns `:masked` for the operator
      class; the actual grant lookup is the caller's (`Samen.Reveal`) job.

  A tenant key reaching a FOREIGN org never gets here — `authorized?/4` already
  denied it at the org-match gate.
  """
  @spec masking_for(key(), String.t()) :: :clear | :masked
  def masking_for(%{plane: :tenant} = key, org_id) do
    if org_match?(key, org_id), do: :clear, else: :masked
  end

  def masking_for(%{plane: :operator}, _org_id), do: :masked
  def masking_for(_key, _org_id), do: :masked

  # --- gates ---------------------------------------------------------------

  defp org_match?(%{org_id: key_org}, org_id), do: key_org == org_id
  defp org_match?(_, _), do: false

  defp declares?(%{scopes: scopes}, action, family) when is_map(scopes) do
    declared_for(scopes, family) ++ declared_for(scopes, :all)
    |> Enum.member?(action)
  end

  defp declares?(_, _, _), do: false

  defp declared_for(scopes, family) do
    Map.get(scopes, family) || Map.get(scopes, to_string_key(family)) || []
  end

  defp to_string_key(family) when is_atom(family), do: Atom.to_string(family)
  defp to_string_key(family), do: family

  # The actor ceiling: the key inherits the minting membership's role. A key can
  # never do what its minter cannot.
  defp within_actor_ceiling?(%{minter_role: role}, :write), do: Role.at_least?(role, :member)
  defp within_actor_ceiling?(%{minter_role: role}, :read), do: Role.at_least?(role, :viewer)
  defp within_actor_ceiling?(_, _), do: false
end
