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
          minter_role: atom() | String.t() | nil,
          # OPTIONAL bounded expiry — a hard time ceiling on the key's life (F3.4).
          # `nil` (a legacy key minted before the expiry gate) is treated as
          # non-expiring by the pure predicate; the DEFAULT minter never mints one
          # (mint clamps to `bounded_expiry/2`), and the deny-on-read query filters
          # on this column so an expired row is never even resolved to an actor.
          expires_at: DateTime.t() | nil
        }

  # F3.4 bounded-expiry policy. Every freshly minted key carries a hard time
  # ceiling; an unbounded (never-expiring) key is the exact posture the gate
  # refuses. Documented defaults — override per deployment via app config if needed.
  @default_ttl_seconds 90 * 24 * 60 * 60
  @max_ttl_seconds 365 * 24 * 60 * 60

  @doc "The documented default key lifetime in seconds (90 days) when none is requested."
  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc "The documented hard ceiling on a key lifetime in seconds (365 days). Requests above it clamp down."
  @spec max_ttl_seconds() :: pos_integer()
  def max_ttl_seconds, do: @max_ttl_seconds

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
  def authorized?(key, action, family, org_id),
    do: authorized?(key, action, family, org_id, DateTime.utc_now())

  @doc """
  As `authorized?/4`, with an explicit `now` — the time gate (F3.4). Adds a fourth,
  fail-closed conjunct to the org/scope/ceiling gates: the key must NOT be expired.
  An expired key authorizes NOTHING regardless of its declared scopes or org match
  (defence-in-depth over the deny-on-read query, which never resolves an expired row).
  """
  @spec authorized?(key(), action(), atom() | String.t(), String.t(), DateTime.t()) :: boolean()
  def authorized?(key, action, family, org_id, now)
      when action in [:read, :write] and is_binary(org_id) do
    not expired?(key, now) and
      org_match?(key, org_id) and
      declares?(key, action, family) and
      within_actor_ceiling?(key, action)
  end

  def authorized?(_key, _action, _family, _org_id, _now), do: false

  @doc """
  Is this key past its bounded expiry at `now`? (F3.4 deny-on-read predicate.)

  `true` iff the key carries an `expires_at` that is at or before `now` (an expiry
  timestamp is a hard ceiling — the instant it is reached the key is dead). A key
  with NO `expires_at` (a legacy pre-gate row) is not expired by this pure predicate;
  the minter never produces one, so this only relaxes for rows that predate the gate.
  """
  @spec expired?(key(), DateTime.t()) :: boolean()
  def expired?(key, now \\ DateTime.utc_now())

  def expired?(%{expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  def expired?(_key, _now), do: false

  @doc """
  Clamp a requested expiry into the bounded window `(now, now + max_ttl]` (F3.4).

    * `nil`                → `now + default_ttl` (the documented default; a key is
      NEVER minted unbounded).
    * a time beyond the max → `now + max_ttl` (the hard ceiling; requests can't buy
      an arbitrarily long-lived credential).
    * a time at/​before `now` → `now + default_ttl` (an already-dead key can't be minted).
    * otherwise             → the requested time.

  Always returns a `DateTime` strictly after `now` — the minted key is always bounded.
  """
  @spec bounded_expiry(DateTime.t() | nil, DateTime.t()) :: DateTime.t()
  def bounded_expiry(requested, now \\ DateTime.utc_now())

  def bounded_expiry(nil, now), do: DateTime.add(now, @default_ttl_seconds, :second)

  def bounded_expiry(%DateTime{} = requested, now) do
    ceiling = DateTime.add(now, @max_ttl_seconds, :second)

    cond do
      DateTime.compare(requested, now) != :gt -> DateTime.add(now, @default_ttl_seconds, :second)
      DateTime.compare(requested, ceiling) == :gt -> ceiling
      true -> requested
    end
  end

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
