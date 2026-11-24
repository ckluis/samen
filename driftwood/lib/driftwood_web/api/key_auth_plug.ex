defmodule DriftwoodWeb.Api.KeyAuthPlug do
  @moduledoc """
  F1 (Gate-5 carry) — resolve the inbound `Authorization: Bearer <api_key>` into a
  `%Samen.Scope{}`-style actor and set it on the conn (doc §external-surface "two key
  classes"), over the freight vertical.

  ## The two key classes (doc §external-surface)

  A `Driftwood.Freight.ApiKey` is bound to exactly one of two planes; the SAME Ash policy
  stack + the SAME `Samen.Api.PiiResolution` egress rule gate both:

    * `:tenant`   — org-bound. Acts as the tenant over its OWN org's freight data. Reads
      its own org's PII (driver `full_name`/`cdl_number`) in CLEAR per its RBAC, with NO
      operator reveal grant (the reveal seam is operator-scoped; it does not sit between a
      tenant and its own records). The actor carries the key's `org_id`, so OrgScope
      isolates it to that org — a cross-org request returns zero rows.
    * `:operator` — the control-plane / cross-tenant class. Masked by default: a subject's
      vaulted CDL is ABSENT unless a live operator reveal grant covers it. The actor is
      flagged `plane: :operator` so `Samen.Api.PiiResolution` sets the field to
      `%Ash.ForbiddenField{}` (omitted by the serializer) without a grant.

  ## The actor shape

  The built actor is the canonical actor map (`id`/`org_id`/`role`) the policies read,
  PLUS `:plane` (drives the masking rule) and `:api_key` (the `Samen.Scope.ApiKey` key map
  so `Samen.Scope.ApiKey.authorized?/4` can enforce the key's declared scopes AND the
  actor ceiling — a key can never out-reach the role that minted it).

  ## Digest, not plaintext

  The key row stores only a SHA-256 digest of the key; the raw key is shown once at mint
  and never persisted in clear. This plug digests the presented bearer token the same way
  and looks the row up by digest.

  Fail closed: a missing/malformed/unknown/revoked key sets NO actor. Downstream, an
  actor-less request hits the org-scope policy's nil-org branch and sees zero rows.

  A key lookup that FAILS (not "no such key": the read errored) is `503` with `Retry-After`, reported once, and the
  request is halted (`Samen.Web.Api.KeyCheckUnavailable`).
  """
  import Plug.Conn

  @doc "The canonical key digest — SHA-256 hex of the raw key material."
  @spec digest(String.t()) :: String.t()
  def digest(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, raw} <- bearer_token(conn),
         {:ok, key_row} <- lookup_key(raw),
         {:ok, actor} <- build_actor(key_row) do
      conn
      |> Ash.PlugHelpers.set_actor(actor)
      |> put_private(:samen_api_actor, actor)
    else
      # The key could not be CHECKED (the lookup failed): 503 + Retry-After, halted — never served, never "bad key".
      :unavailable -> Samen.Web.Api.KeyCheckUnavailable.send(conn)
      # Fail closed: no valid key → no actor. The org-scope policy denies (nil org).
      _ -> conn
    end
  end

  # --- key resolution ------------------------------------------------------

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw | _] when byte_size(raw) > 0 -> {:ok, raw}
      _ -> :error
    end
  end

  defp lookup_key(raw) do
    digest = digest(raw)

    # This IS the auth step — the key row lookup cannot itself require an actor. A
    # revoked key (revoked_at set) is rejected.
    Samen.Scope.ApiKey.active_query(Driftwood.Freight.ApiKey, digest)
    |> Ash.Query.ensure_selected([:id, :org_id, :plane, :scopes, :minter_role, :minter_user_id])
    # authz-scope: API-key AUTH-STEP lookup keyed on the SHA-256 digest of a server-minted random token — no actor/org
    # exists until this row resolves (revoked filtered out; unmatched digest => :error; a duplicate digest makes read_one error => :unavailable — both fail closed)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :error
      {:ok, key_row} -> {:ok, key_row}
      # A lookup that FAILED is an outage, not "an invalid key": report it once by name and exception module and
      # answer 503 (`:unavailable`), failing closed.
      {:error, error} ->
        Samen.Web.Reads.Guard.report(:driftwood_api_key_lookup, nil, error)
        :unavailable
    end
  end

  defp build_actor(key_row) do
    # A key with no/unknown `minter_role` authorizes nothing (`Samen.Scope.ApiKey.acting_role/1`): refused here
    # rather than given `role: nil`.
    with {:ok, role} <- Samen.Scope.ApiKey.acting_role(key_row) do
      org_id = to_string(key_row.org_id)

      key = %{
        org_id: org_id,
        plane: key_row.plane,
        scopes: key_row.scopes || %{},
        minter_role: role
      }

      actor = %{
        id: key_row.minter_user_id || ("apikey:" <> to_string(key_row.id)),
        org_id: org_id,
        role: role,
        plane: key_row.plane,
        api_key: key
      }

      {:ok, actor}
    end
  end
end
