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

  require Ash.Query

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
  THE api-key auth-step lookup query — the one place that knows which rows may authenticate.

  Every host's key check (demo's plug, driftwood's plug, pawchart's MCP resolver, the generated
  app's plug) builds its lookup from THIS query, so a host cannot forget a condition:

    * `token_digest == digest` (the SHA-256 of the presented key);
    * not revoked (`revoked_at` is nil);
    * not expired — `expires_at` is nil (a legacy, non-expiring row) or `> now`. A resource
      with no `expires_at` column must declare `samen_key_expiryless?/0` (driftwood's `Freight.ApiKey`; see
      `expiry_enforced?/1`), else this RAISES.

  Returns an `Ash.Query`; the CALLER reads it `authorize?: false` (this IS the auth step — no
  actor exists yet) and carries the `# authz-scope:` marker. A guard test
  (`Samen.ApiKeyLookupGuardTest`) fails if a host or template keys a lookup on `token_digest`
  without going through here.
  """
  @spec active_query(module(), String.t(), DateTime.t()) :: Ash.Query.t()
  def active_query(resource, digest, now \\ DateTime.utc_now()) when is_binary(digest) do
    expiry? = expiry_enforced?(resource)

    query =
      resource
      |> Ash.Query.filter(token_digest == ^digest)
      |> Ash.Query.filter(is_nil(revoked_at))

    if expiry? do
      Ash.Query.filter(query, is_nil(expires_at) or expires_at > ^now)
    else
      query
    end
  end

  @doc """
  Does the key resource enforce an expiry (`true`), or has it DECLARED that it has none (`false`)? A resource
  with an `:expires_at` attribute is enforced. A resource that authenticates keys with NO expiry column must say
  so on itself by defining `samen_key_expiryless?/0` returning `true` (driftwood's `Freight.ApiKey` is the one
  today: F3.4 does not hold for its API keys; see CHANGELOG). The declaration lives on the resource, so this
  framework module names no host. A resource that is neither (typically a column named something else, e.g.
  `:expiry`) RAISES: a forgotten or renamed column can never silently turn expiry off. The host test suites call
  this over every key-check site's resource, so the mistake fails in CI, not as a 500 on every request.
  """
  @spec expiry_enforced?(module()) :: boolean()
  def expiry_enforced?(resource) do
    cond do
      Ash.Resource.Info.attribute(resource, :expires_at) -> true
      expiryless_declared?(resource) -> false
      true ->
        raise ArgumentError,
              "#{inspect(resource)} has no :expires_at attribute and does not declare `def samen_key_expiryless?, do: true` " <>
                "— refusing to build a key lookup that would silently skip the expiry gate (name the column " <>
                ":expires_at, or declare the resource expiryless)"
    end
  end

  defp expiryless_declared?(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :samen_key_expiryless?, 0) and
      resource.samen_key_expiryless?() == true
  end

  @doc """
  The role a resolved key row acts with: its `minter_role` if it is a real, in-set role, else
  `:error`. Every key-check site (demo's and driftwood's plugs, pawchart's MCP resolver, the
  generated plug) calls this and REFUSES to authenticate on `:error` — it never substitutes a
  default role, because an actor with `role: nil` would pass OrgScope-only resources. (The pure
  `authorized?/4` predicate would also deny such a key, but no host calls `authorized?/4` at
  request time today: declared `scopes` are not enforced per request.)
  """
  @spec acting_role(%{optional(:minter_role) => term(), optional(atom()) => term()}) ::
          {:ok, atom()} | :error
  def acting_role(%{minter_role: role}) do
    case Enum.find(Role.all(), &(&1 == role or Atom.to_string(&1) == role)) do
      nil -> :error
      valid -> {:ok, valid}
    end
  end

  def acting_role(_), do: :error

  @doc """
  The membership a key row is bound to, read with a bare repo query (no policy can hide it from
  the check that must see it): `{:ok, %{user_id, org_id, role, status}}` | `:not_found` |
  `{:error, reason}`. `resource` is the key resource (its `:membership` relationship names the
  table); `membership_id` is the key's FK.
  """
  @spec membership_row(module(), term()) :: {:ok, map()} | :not_found | {:error, term()}
  def membership_row(resource, membership_id) do
    with %{type: :belongs_to} = rel <- Ash.Resource.Info.relationship(resource, :membership),
         dest = rel.destination,
         repo when not is_nil(repo) <-
           AshPostgres.DataLayer.Info.repo(dest, :read) || AshPostgres.DataLayer.Info.repo(dest),
         table when not is_nil(table) <- AshPostgres.DataLayer.Info.table(dest),
         [pk, user, org, role, status] <-
           Enum.map([rel.destination_attribute, :user_id, :org_id, :role, :status], &source(dest, &1)),
         false <- Enum.any?([pk, user, org, role, status], &is_nil/1),
         {:ok, bin} <- Ecto.UUID.dump(to_string(membership_id)) do
      sql = "SELECT #{user}, #{org}, #{role}, #{status} FROM #{table} WHERE #{pk} = $1 LIMIT 1"

      case repo.query(sql, [bin]) do
        {:ok, %{rows: [[u, o, r, st]]}} ->
          {:ok, %{user_id: load_uuid(u), org_id: load_uuid(o), role: r, status: st}}

        {:ok, %{rows: []}} ->
          :not_found

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :membership_unresolvable}
    end
  end

  defp source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp load_uuid(nil), do: nil

  defp load_uuid(bin) when byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  defp load_uuid(other), do: other

  @doc """
  The role a key ACTS with at use time: the LOWER of its stored `minter_role` and the role its
  minting membership holds NOW. `membership` is the key's membership as read at the auth step
  (`%{org_id:, role:, status:}`); a key whose membership is missing (`nil`), not `"active"`, in a
  DIFFERENT org than the key's own `org_id`, or has an out-of-set role is refused (`:error`). So demoting a member lowers every key they minted, and
  removing or suspending them kills those keys, with no per-key sweep.

  Every key-check site calls this (after `acting_role/1`); it is the single place that knows the rule.
  """
  @spec effective_role(map(), map() | nil) :: {:ok, atom()} | :error
  def effective_role(key_row, %{role: membership_role, status: "active"} = membership) do
    with :ok <- same_org(key_row, membership),
         {:ok, stored} <- acting_role(key_row),
         {:ok, current} <- acting_role(%{minter_role: membership_role}) do
      {:ok, if(Role.rank(stored) <= Role.rank(current), do: stored, else: current)}
    end
  end

  def effective_role(_key_row, _membership), do: :error

  # The membership must belong to the KEY's org. A site that builds its actor's `org_id` from the membership
  # (demo, the generated plug) would otherwise act in whatever org a rewritten membership row names. Both orgs
  # must be present and equal; anything else (a missing or unloaded column) fails closed.
  defp same_org(%{org_id: key_org}, %{org_id: mbr_org}) when is_binary(key_org) and is_binary(mbr_org) do
    if key_org == mbr_org, do: :ok, else: :error
  end

  defp same_org(_key_row, _membership), do: :error

  @doc """
  The ACTIVE membership of `user_id` in `org_id` — the LOWEST-ranked one if the user holds several (for a key that records a minter user id rather
  than a membership FK — driftwood's Freight keys). `{:ok, membership}` | `:error` (none, not a
  UUID — all fail closed) | `{:error, reason}` (the READ itself failed: an outage, not "no such
  membership", so a caller answers "could not check" and reports it, never "bad key").
  """
  @spec membership_for_user(module(), term(), term()) :: {:ok, map()} | :error | {:error, term()}
  def membership_for_user(membership_resource, org_id, user_id) do
    with {:ok, uid} <- Ecto.UUID.cast(to_string(user_id)),
         {:ok, oid} <- Ecto.UUID.cast(to_string(org_id)) do
      membership_resource
      |> Ash.Query.filter(user_id == ^uid and org_id == ^oid and status == "active")
      |> Ash.Query.select([:id, :org_id, :user_id, :role, :status])
      # authz-scope: API-key AUTH-STEP membership lookup (no actor exists yet), keyed on the key's own user + org
      |> Ash.read(authorize?: false)
      |> case do
        # Nothing in the schema forbids two active memberships of one user in one org (no unique index on
        # (org_id, user_id)): take the LOWEST-ranked one (id breaks a tie), so the key's cap never depends on row
        # order and a second, higher-ranked row can never raise it.
        {:ok, [_ | _] = memberships} -> {:ok, Enum.min_by(memberships, &{Role.rank(&1.role), to_string(&1.id)})}
        {:ok, []} -> :error
        {:error, error} -> {:error, error}
      end
    else
      _ -> :error
    end
  end

  @doc """
  Is this key past its bounded expiry at `now`? (F3.4 deny-on-read predicate.)

  `true` iff the key carries an `expires_at` that is at or before `now` (an expiry
  timestamp is a hard ceiling — the instant it is reached the key is dead). A key
  with NO `expires_at` (a legacy pre-gate row) is not expired by this pure predicate;
  the minter never produces one, so this only relaxes for rows that predate the gate.
  """
  @spec expired?(
          %{optional(:expires_at) => DateTime.t() | nil, optional(atom()) => term()},
          DateTime.t()
        ) :: boolean()
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
