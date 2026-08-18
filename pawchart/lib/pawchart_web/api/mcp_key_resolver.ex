defmodule PawChartWeb.Api.McpKeyResolver do
  @moduledoc """
  T142 (folded into T157) — the REAL, constant-time `:actor_resolver` for pawchart's mounted
  MCP endpoint (`samen_mcp_route`, ADR-043 §9). Resolves an inbound `Authorization: Bearer <token>`
  into a `%Samen.Scope{}` scoped to the token owner's org, or `:error` (→ the MCP plug returns 401).

  ## Constant-time, org-scoped (the T142 contract)

  Per-operator API tokens are stored ONLY as a SHA-256 digest on `PawChart.Operator.ApiKey`
  (`pok_token_digest`; the raw token is shown once at mint, never persisted in clear). This
  resolver:

    1. digests the presented bearer token the same way (`:crypto.hash(:sha256, raw)`);
    2. looks the key row up by that digest (a revoked key — `revoked_at` set — is rejected);
    3. confirms the match with `Plug.Crypto.secure_compare/2` over the stored digest — a
       constant-time comparison, NEVER a byte-by-byte `==` on the raw token (a timing oracle);
    4. builds a `%Samen.Scope{}` whose `org_id`/`plane`/`role` come from THAT key's owner, so the
       MCP engine's hard `org_id ==` filter isolates the caller to its own org (an org-A token can
       never reach org-B data).

  Fail CLOSED: a missing/malformed/unknown/revoked/mismatched key → `:error` (401). This is the
  enforcing layer the T157/T142 e2e auth test pins (unauth → 401, forged → 401, cross-org denied).
  """
  require Ash.Query

  @doc "The canonical key digest — SHA-256 hex of the raw key material."
  @spec digest(String.t()) :: String.t()
  def digest(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc """
  Resolve a raw bearer token into `{:ok, %Samen.Scope{}}` or `:error`. Wired as the MCP mount's
  `:actor_resolver` MFA (`{PawChartWeb.Api.McpKeyResolver, :resolve_scope, []}`), called by
  `Samen.Web.AI.McpPlug` with the raw token.
  """
  @spec resolve_scope(String.t() | nil) :: {:ok, Samen.Scope.t()} | :error
  def resolve_scope(raw) when is_binary(raw) and byte_size(raw) > 0 do
    digest = digest(raw)

    case lookup(digest) do
      {:ok, row} ->
        # Constant-time final gate (T142): the raw token is NEVER compared byte-by-byte; only
        # its digest is, via secure_compare over the stored digest. A forged token has no row
        # (the lookup already returned :error) — this line is the belt-and-suspenders equal-time
        # confirmation on the row that DID match by digest.
        if Plug.Crypto.secure_compare(digest, to_string(row.token_digest)) do
          {:ok, scope_for(row)}
        else
          :error
        end

      :error ->
        :error
    end
  end

  def resolve_scope(_), do: :error

  # This IS the auth step — the key row lookup cannot itself require an actor. A forged/unknown
  # token digests to a value that matches NO row → :error. A revoked key (revoked_at set) is
  # rejected. The `token_digest == ^digest` equality is the enforcing filter for forged-rejection.
  defp lookup(digest) do
    PawChart.Operator.ApiKey
    |> Ash.Query.filter(token_digest == ^digest)
    |> Ash.Query.filter(is_nil(revoked_at))
    |> Ash.Query.ensure_selected([:id, :org_id, :plane, :scopes, :minter_role, :token_digest])
    # authz-scope: MCP API-key AUTH-STEP lookup keyed on the unique token digest — no actor/org
    # exists until this row resolves (revoked filtered out; unmatched digest => :error, fail closed)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :error
      {:ok, row} -> {:ok, row}
      {:error, _} -> :error
    end
  end

  defp scope_for(row) do
    org_id = to_string(row.org_id)

    %Samen.Scope{
      actor: %{
        id: "apikey:" <> to_string(row.id),
        org_id: org_id,
        role: row.minter_role || :member,
        plane: row.plane || :tenant
      },
      context: nil
    }
  end
end
