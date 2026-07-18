defmodule Samen.Web.Settings.ApiKeys do
  @moduledoc """
  The framework API-KEY management engine (WS-E E5.2; ADR-029; AC-G18-3/4) — mint /
  list / revoke over the existing `Identity.ApiKey` resource, credential-hygiene
  correct by construction.

  ## Show-once, digest-only (AC-G18-3, RP-ST-2)

  `mint/3` generates the raw key material, stores ONLY its SHA-256 digest
  (`token_digest`) on the row, and returns the raw key ONCE. The raw is never
  persisted and never read back — the UI cannot leak a key it never stores. `list/2`
  returns a digest-prefix + plane + scopes + minter role + timestamps, NEVER the key.

  ## Minter role ceiling (AC-G18-4, RP-ST-3)

  A minted key can never out-reach the membership that mints it. `effective_scopes/2`
  intersects the REQUESTED scopes with the minter role's ceiling BEFORE the row is
  written — a `viewer`-minted key is read-only regardless of what write scopes were
  requested (`write` needs `>= member`; `read` needs `>= viewer`). This is the mint-time
  half of the `Samen.Scope.ApiKey.authorized?/4` use-time ceiling; storing the
  ceiling-bounded scope set means the row itself can't carry escalated authority.
  Sabotaging the intersection (storing the requested scopes verbatim) FAILS the ceiling
  red-path.
  """

  require Ash.Query

  alias Samen.Scope.Role
  alias Samen.Web.Mount

  @doc "The canonical key digest — SHA-256 hex of the raw key material (never the key)."
  @spec digest(String.t()) :: String.t()
  def digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc "Generate fresh, high-entropy raw key material. Returned once at mint, never stored."
  @spec generate_raw() :: String.t()
  def generate_raw, do: "sk_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  @doc """
  The mint-time authority ceiling (RP-ST-3): intersect `requested` scopes
  (`%{family => [:read | :write]}`) with what a `minter_role` may do. `:write` is kept
  only for `>= member`; `:read` only for `>= viewer`. Families left empty are dropped.
  """
  @spec effective_scopes(map(), atom() | String.t() | nil) :: map()
  def effective_scopes(requested, minter_role) when is_map(requested) do
    can_write = Role.at_least?(minter_role, :member)
    can_read = Role.at_least?(minter_role, :viewer)

    requested
    |> Enum.map(fn {family, actions} -> {family, keep_actions(actions, can_read, can_write)} end)
    |> Enum.reject(fn {_family, kept} -> kept == [] end)
    |> Map.new()
  end

  def effective_scopes(_requested, _role), do: %{}

  defp keep_actions(actions, can_read, can_write) when is_list(actions) do
    Enum.filter(actions, fn
      a when a in [:write, "write"] -> can_write
      a when a in [:read, "read"] -> can_read
      _ -> false
    end)
  end

  defp keep_actions(_actions, _can_read, _can_write), do: []

  @doc """
  Mint a new key for `scope` (admin-gated by the `ApiKey` create policy). `opts`:

    * `:membership_id` — REQUIRED. The minting membership (the actor ceiling / same-org FK).
    * `:minter_role`   — REQUIRED. The minting membership's role.
    * `:plane`         — `:tenant` (default) or `:operator`.
    * `:scopes`        — requested `%{family => [:read | :write]}` (default `%{}`).

  Returns `{:ok, raw, key_row}` — `raw` shown once, `key_row` stores only the digest —
  or `{:error, reason}`.
  """
  def mint(mount, scope, opts) do
    membership_id = Keyword.fetch!(opts, :membership_id)
    minter_role = Keyword.fetch!(opts, :minter_role)
    plane = Keyword.get(opts, :plane, :tenant)
    requested = Keyword.get(opts, :scopes, %{})

    raw = generate_raw()

    # `token_digest` is a private attribute (`public?: false`) — it is set via
    # `force_change_attribute`, NEVER as a public action input, and stores ONLY the
    # digest. The raw is never a changeset value, so it can never be persisted.
    attrs = %{
      plane: plane,
      scopes: effective_scopes(requested, minter_role),
      minter_role: minter_role,
      membership_id: membership_id,
      org_id: scope_org_id(scope)
    }

    Mount.resource(mount, ApiKey)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.Changeset.force_change_attribute(:token_digest, digest(raw))
    |> Ash.create(scope: scope)
    |> case do
      {:ok, row} -> {:ok, raw, row}
      {:error, error} -> {:error, error}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  List the org's keys for `scope` as SAFE views — digest prefix, plane, scopes, minter
  role, created/revoked timestamps. NEVER the raw key (it isn't stored). Newest first.
  """
  def list(mount, scope) do
    Mount.resource(mount, ApiKey)
    |> Ash.Query.ensure_selected([
      :token_digest,
      :plane,
      :scopes,
      :minter_role,
      :revoked_at,
      :inserted_at,
      :org_id,
      :id
    ])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
    |> Enum.map(&safe_view/1)
  rescue
    _ -> []
  end

  @doc "Revoke a key (sets `revoked_at`) — admin-gated. `{:ok, view}` or `{:error, reason}`."
  def revoke(mount, scope, key_id) when is_binary(key_id) do
    with [row | _] <-
           Mount.resource(mount, ApiKey)
           |> Ash.Query.filter(id == ^key_id)
           |> Ash.Query.limit(1)
           |> Ash.read!(scope: scope) do
      row
      |> Ash.Changeset.for_update(:update, %{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)}, scope: scope)
      |> Ash.update(scope: scope)
      |> case do
        {:ok, updated} -> {:ok, safe_view(updated)}
        {:error, error} -> {:error, error}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  def revoke(_mount, _scope, _key_id), do: {:error, :not_found}

  # -- private -----------------------------------------------------------------

  # The SAFE, never-leaks view — a short digest prefix (an identifier, not the key),
  # plus bounded metadata. The raw key is nowhere in here (it is nowhere on the row).
  defp safe_view(row) do
    %{
      id: row.id,
      digest_prefix: String.slice(row.token_digest || "", 0, 12),
      plane: row.plane,
      scopes: row.scopes || %{},
      minter_role: row.minter_role,
      revoked_at: row.revoked_at,
      inserted_at: Map.get(row, :inserted_at),
      revoked?: not is_nil(row.revoked_at)
    }
  end

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp scope_org_id(%{org_id: org_id}), do: org_id
  defp scope_org_id(_), do: nil
end
