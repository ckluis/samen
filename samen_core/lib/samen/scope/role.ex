defmodule Samen.Scope.Role do
  @moduledoc """
  The canonical Identity RBAC role model (T3.1; doc scope table `role`).

  A **closed, ranked** set of roles. RBAC is rank-based: an actor may only grant,
  alter, or assume a role at or below their own rank. This is the mechanism behind
  the "role escalation denied" red path — a `member` cannot mint an `admin`, and an
  `admin` cannot mint an `owner`.

  ## The ranks

      :owner   (rank 3) — full control of the org, including billing + destroy
      :admin   (rank 2) — manage members, roles (below admin), api_keys, invitations
      :member  (rank 1) — normal tenant-plane read/write within the org
      :viewer  (rank 0) — read-only within the org

  Ranks are **relative within an org**. They do NOT cross orgs — a rank-3 owner in
  org A has rank 0 (no access) in org B. Cross-org isolation is the org-scope
  policy's job; rank is the *intra*-org escalation guard.

  ## Why a closed set

  Roles are stored as a bounded enum (never free text), so:

    * they are safe metric labels / audit tokens (bounded cardinality — T2.8);
    * `Samen.Scope.new/1` can resolve a string role to a known atom without
      `String.to_atom/1` on untrusted input (fail closed to `nil` = unprivileged);
    * a new role is an explicit, reviewed addition here — not a typo a tenant can
      inject via an api call.

  Tier-2 custom objects (T3.9) and Tier-1 custom fields (T3.8) are the malleability
  path for tenant-defined *data*; roles are infrastructure and stay closed.
  """

  @roles [
    owner: 3,
    admin: 2,
    member: 1,
    viewer: 0
  ]

  @doc "The closed list of role atoms, highest-rank first."
  @spec all() :: [atom()]
  def all, do: Enum.map(@roles, fn {r, _} -> r end)

  @doc "The rank of a role (higher = more privileged). Unknown roles rank -1 (fail closed)."
  @spec rank(atom() | String.t() | nil) :: integer()
  def rank(role) when is_atom(role), do: Keyword.get(@roles, role, -1)

  def rank(role) when is_binary(role) do
    case Enum.find(all(), fn r -> Atom.to_string(r) == role end) do
      nil -> -1
      atom -> rank(atom)
    end
  end

  def rank(_), do: -1

  @doc "True if `role` is a known, in-set role."
  @spec valid?(term()) :: boolean()
  def valid?(role), do: rank(role) >= 0

  @doc """
  True if an actor with `actor_role` may manage (grant/alter/revoke) `target_role`.

  The rule (strict, fail closed): the actor's rank must be **>= admin (2)** AND
  **strictly greater than** the target role's rank. So:

    * an `owner` (3) may manage `admin`/`member`/`viewer` (2/1/0) but NOT another
      `owner` (3) — no lateral escalation;
    * an `admin` (2) may manage `member`/`viewer` (1/0) but NOT `admin` or `owner`;
    * a `member` (1) may manage NOTHING (rank < admin) — the escalation red path;
    * a `viewer` (0) may manage NOTHING.

  This is what the `role escalation denied` red-path proves: `may_manage?(:member,
  :admin) == false` and `may_manage?(:admin, :owner) == false`.
  """
  @spec may_manage?(atom() | String.t() | nil, atom() | String.t() | nil) :: boolean()
  def may_manage?(actor_role, target_role) do
    actor_rank = rank(actor_role)
    target_rank = rank(target_role)

    actor_rank >= rank(:admin) and target_rank >= 0 and actor_rank > target_rank
  end

  @doc """
  True if an actor with `actor_role` is at least `required_role`.

  `at_least?(:admin, :member) == true` (admin outranks member);
  `at_least?(:member, :admin) == false`. Unknown/`nil` actor roles are always
  below any real role (fail closed).
  """
  @spec at_least?(atom() | String.t() | nil, atom() | String.t()) :: boolean()
  def at_least?(actor_role, required_role) do
    r = rank(actor_role)
    r >= 0 and r >= rank(required_role)
  end
end
