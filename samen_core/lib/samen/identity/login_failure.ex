defmodule Samen.Identity.LoginFailure do
  @moduledoc """
  The engine behind the `Identity.LoginFailure` durable brute-force counter
  (ADR-038 §6.4; T109). Mirrors `Samen.Identity.SignIn`/`Confirm`/`Reset` etc — a
  GENERIC module operating on a host's resource module (the `<Host>.Identity.LoginFailure`
  materialized by `Samen.Scopes.Identity.Blueprint.define_login_failure/5`), never
  hardcoding a host.

  ## Why the write path is raw SQL, not an Ash changeset

  `bump!/4` and `reset!/3` issue parametrized SQL directly against the resource's
  table (via `AshPostgres.DataLayer.Info.repo/1` + `.table/1` + attribute
  `.source` introspection), not Ash create/update actions. The property this
  table exists for — "increment atomically under concurrent brute force, but
  reset the whole row the instant the window has expired, in ONE round trip with
  no read-then-write race" — is exactly what Postgres's
  `INSERT ... ON CONFLICT ... DO UPDATE SET x = CASE WHEN ... END` expresses
  race-free. This mirrors `Samen.Webhook.Event`'s raw-Ecto write path (ADR-038
  §5.3) — a documented, deliberate mechanism choice, not a chokepoint bypass:
  `key_value` is a non-reversible bidx or an opaque credential UUID, never PII,
  so none of the vault/PII write guards (`Samen.Pii.WriteGuard`,
  `Samen.Vault.Change`) apply to this resource regardless of write path. The
  resource stays a NORMAL governed Ash resource for everything else — reads,
  `schema.dict.json` cataloging, the abbrev registry, policies, and the
  `Samen.Retention` sweep's `:destroy` action all see it like any other Identity
  resource.

  ## Semantics

  `bump!/4` — call on EVERY failed attempt (the same cadence T103's ETS counter
  already bumps at; distinct from the O(windows)-bounded `aud_event` edge rows,
  which stay driven by the ETS counter unchanged). If the existing row's
  `window_started_at` is still within `window_seconds` of now, `failure_count`
  increments; otherwise the row resets to `failure_count: 1` with a fresh
  `window_started_at`. Returns the resulting count.

  `reset!/3` — call on a SUCCESSFUL login (deletes the row for that key; ADR
  text: "successful login -> reset").

  `over_limit?/5` — the restart-survival enforcement seam: true when the
  DURABLE row shows `failure_count >= limit` AND the window is still live. Used
  ADDITIONALLY to (never in place of) the ETS check, so a restart can only make
  the sign-in gate STRICTER (a still-locked-out attacker stays locked out),
  never weaker (`Samen.Web.RateLimit`'s ETS check runs first and unchanged).

  `count/3` — a plain read of the current durable count (0 if no row).
  """

  require Ash.Query

  @type key_kind :: :email_bidx | :credential

  @doc """
  Atomically bump the durable failure counter for `{key_kind, key_value}` on
  `resource` (a host's mounted `Identity.LoginFailure`, e.g.
  `Mount.resource(mount, LoginFailure)`). Returns the resulting `failure_count`.
  """
  @spec bump!(module(), key_kind(), String.t(), pos_integer()) :: pos_integer()
  def bump!(resource, key_kind, key_value, window_seconds)
      when key_kind in [:email_bidx, :credential] and is_binary(key_value) and
             is_integer(window_seconds) and window_seconds > 0 do
    repo = repo!(resource)
    table = table!(resource)
    c = columns(resource)
    now = now()
    cutoff = DateTime.add(now, -window_seconds, :second)

    sql = """
    INSERT INTO #{table}
      (#{c.id}, #{c.key_kind}, #{c.key_value}, #{c.failure_count}, #{c.window_started_at}, #{c.last_failed_at}, #{c.inserted_at}, #{c.updated_at})
    VALUES (gen_random_uuid(), $1, $2, 1, $3, $3, $3, $3)
    ON CONFLICT (#{c.key_kind}, #{c.key_value}) DO UPDATE SET
      #{c.failure_count} = CASE WHEN #{table}.#{c.window_started_at} > $4
                              THEN #{table}.#{c.failure_count} + 1
                              ELSE 1
                            END,
      #{c.window_started_at} = CASE WHEN #{table}.#{c.window_started_at} > $4
                                  THEN #{table}.#{c.window_started_at}
                                  ELSE $3
                                END,
      #{c.last_failed_at} = $3,
      #{c.updated_at} = $3
    RETURNING #{c.failure_count}
    """

    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(repo, sql, [Atom.to_string(key_kind), key_value, now, cutoff])

    count
  end

  @doc """
  Reset (delete) the durable row for `{key_kind, key_value}` — a successful login
  clears the accumulated brute-force signal for that key. A no-op (still `:ok`)
  when no row exists.
  """
  @spec reset!(module(), key_kind(), String.t()) :: :ok
  def reset!(resource, key_kind, key_value)
      when key_kind in [:email_bidx, :credential] and is_binary(key_value) do
    repo = repo!(resource)
    table = table!(resource)
    c = columns(resource)

    sql = "DELETE FROM #{table} WHERE #{c.key_kind} = $1 AND #{c.key_value} = $2"
    Ecto.Adapters.SQL.query!(repo, sql, [Atom.to_string(key_kind), key_value])
    :ok
  end

  @doc """
  The durable restart-survival enforcement check (ADR-038 §6.4's "the
  lockout/throttle decision survives restart" done-criterion): true when the
  row's `failure_count >= limit` AND `window_started_at` is still within
  `window_seconds` of now — i.e. a still-live window that was already over
  limit before a restart. A stale (window-expired) or absent row is never
  over-limit. Read-only — plain Ash read (no atomicity concern; this never
  mutates).
  """
  @spec over_limit?(module(), key_kind(), String.t(), pos_integer(), pos_integer()) :: boolean()
  def over_limit?(resource, key_kind, key_value, limit, window_seconds)
      when is_integer(limit) and limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    cutoff = DateTime.add(now(), -window_seconds, :second)

    resource
    |> Ash.Query.filter(key_kind == ^key_kind and key_value == ^key_value and window_started_at > ^cutoff)
    |> Ash.Query.select([:failure_count])
    # authz-scope: pre-auth rate-limit counter read keyed on the unique (key_kind, key_value)
    # pair (<=1 row); no actor exists on the failed-login path
    |> Ash.read!(authorize?: false)
    |> case do
      [%{failure_count: n}] -> n >= limit
      [] -> false
    end
  end

  @doc "The current durable `failure_count` for `{key_kind, key_value}` (0 if no row)."
  @spec count(module(), key_kind(), String.t()) :: non_neg_integer()
  def count(resource, key_kind, key_value) when key_kind in [:email_bidx, :credential] do
    resource
    |> Ash.Query.filter(key_kind == ^key_kind and key_value == ^key_value)
    |> Ash.Query.select([:failure_count])
    # authz-scope: pre-auth rate-limit counter read keyed on the unique (key_kind, key_value)
    # pair (<=1 row); no actor exists on the failed-login path
    |> Ash.read!(authorize?: false)
    |> case do
      [%{failure_count: n}] -> n
      [] -> 0
    end
  end

  @doc """
  A `Samen.Retention.Spec` for `resource`'s 30-day idle prune (ADR-038 §6.4):
  rows whose `last_failed_at` is older than `ttl_seconds` (default 30 days) are
  hard-deleted. A host wires this into its own `:retention_specs` config
  (`Samen.Retention.sweep/2`'s caller) alongside its other specs — this
  function only builds the spec value; scheduling the sweep is the maintenance
  queue owner's job (the `Samen.Webhook.Event` precedent, ADR-038 §5.3).
  """
  @spec retention_spec(module(), keyword()) :: Samen.Retention.Spec.t()
  def retention_spec(resource, opts \\ []) do
    thirty_days = 30 * 24 * 60 * 60
    ttl_seconds = Keyword.get(opts, :ttl_seconds, thirty_days)

    %Samen.Retention.Spec{
      resource: resource,
      ttl_seconds: ttl_seconds,
      action: :delete,
      timestamp_field: :last_failed_at
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp repo!(resource) do
    AshPostgres.DataLayer.Info.repo(resource) ||
      raise "Samen.Identity.LoginFailure: #{inspect(resource)} has no AshPostgres repo configured"
  end

  defp table!(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp columns(resource) do
    src = fn name -> Ash.Resource.Info.attribute(resource, name).source end

    %{
      id: src.(:id),
      key_kind: src.(:key_kind),
      key_value: src.(:key_value),
      failure_count: src.(:failure_count),
      window_started_at: src.(:window_started_at),
      last_failed_at: src.(:last_failed_at),
      inserted_at: src.(:inserted_at),
      updated_at: src.(:updated_at)
    }
  end
end
