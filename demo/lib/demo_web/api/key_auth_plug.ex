defmodule DemoWeb.Api.KeyAuthPlug do
  @moduledoc """
  Resolve the inbound `Authorization: Bearer <api_key>` into a `%Samen.Scope{}`
  actor and set it on the conn (T3.11; doc §external-surface "two key classes").

  ## The two key classes (doc §external-surface)

  An `api_key` is bound to exactly one of two planes; the SAME Ash policy stack gates
  both (the key can never out-reach its actor). This plug reads the plane off the
  persisted `Demo.Identity.ApiKey` row and builds the actor accordingly:

    * `:tenant`   — org-bound. Acts as the tenant over its OWN org's data. Reads its
      own org's PII in clear per the tenant's RBAC, with NO operator reveal grant
      (the reveal seam is operator-scoped; it does not sit between a tenant and its
      own records). The actor carries the key's `org_id`, so the org-scope policy
      isolates it to that org — a cross-org request returns zero rows.
    * `:operator` — the control-plane / cross-tenant class. Masked by default: a
      subject's vaulted plaintext is ABSENT (or `••••`) unless an operator reveal
      grant covers it. The actor is flagged `plane: :operator` so the serialization
      masking layer (`DemoWeb.Api.OperatorMask`) strips vaulted fields absent a grant.

  ## The actor shape

  The built actor is the canonical `%Samen.Scope{}` actor map (id/org_id/role) — the
  shape the T3.1 policies already read — PLUS two API-only keys the API layer reads:

    * `:plane`   — `:tenant | :operator` (drives the masking rule).
    * `:api_key` — the `Samen.Scope.ApiKey` key map (org_id/plane/scopes/minter_role),
      so `Samen.Scope.ApiKey.authorized?/4` can enforce the key's declared scopes AND
      the actor ceiling. A key can never out-reach the membership that minted it.

  The actor's `:role` is the key's `minter_role` — the key inherits its minter's rank
  (a viewer-minted key is read-only regardless of its declared scopes; RBAC on the
  resource sees this role).

  ## Digest, not plaintext

  The key row stores only a SHA-256 digest of the key (`key_token_digest`); the raw
  key is shown once at mint and never persisted in clear. This plug digests the
  presented bearer token the same way and looks the row up by digest — a constant
  set of DB reads, no plaintext key at rest.

  Fail closed: a missing/malformed/unknown/revoked key sets NO actor. Downstream, an
  actor-less request hits the org-scope policy's nil-org branch and sees zero rows.
  """
  import Plug.Conn
  require Ash.Query

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
      # F3.4 — best-effort last-use stamp (never gates auth, never aborts the request).
      touch_last_used(key_row)

      conn
      |> Ash.PlugHelpers.set_actor(actor)
      # Stash the actor on a private assign too so the masking layer can read the
      # plane without re-resolving the key.
      |> put_private(:samen_api_actor, actor)
    else
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
    now = DateTime.utc_now()

    # Look up the api_key row by digest, unauthorized (this IS the auth step — the
    # key row lookup cannot itself require an actor). A revoked key (revoked_at set)
    # is rejected. F3.4 DENY-ON-READ: an EXPIRED key (expires_at <= now) is likewise
    # never resolved — the row is filtered out at the query, so no actor is built and
    # the request fails closed at the org-scope nil-org branch (defence-in-depth with
    # `Samen.Scope.ApiKey.authorized?/5`, which also refuses an expired key at use).
    Demo.Identity.ApiKey
    |> Ash.Query.filter(token_digest == ^digest)
    |> Ash.Query.filter(is_nil(revoked_at))
    |> Ash.Query.filter(is_nil(expires_at) or expires_at > ^now)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :error
      {:ok, key_row} -> {:ok, key_row}
      {:error, _} -> :error
    end
  end

  # F3.4 — stamp last_used_at via the least-privilege `:mark_used` action. Best-effort:
  # a failure here NEVER affects the resolved actor or the request outcome.
  defp touch_last_used(key_row) do
    key_row
    |> Ash.Changeset.for_update(:mark_used, %{
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Ash.update(authorize?: false)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_actor(key_row) do
    # The membership that minted this key carries (user_id, org_id, role). Load it to
    # resolve the actor's org boundary — selecting the attributes we read so they are
    # not %Ash.NotLoaded{}. The key's own `plane`/`scopes`/`minter_role` come off the
    # key row.
    membership_query =
      Demo.Identity.Membership
      |> Ash.Query.select([:id, :org_id, :user_id, :role])

    case Ash.load(key_row, [membership: membership_query], authorize?: false) do
      {:ok, %{membership: %{} = mbr} = key_row} ->
        org_id = fetch(mbr, [:org_id, :mbs_org_id])
        user_id = fetch(mbr, [:user_id, :mbs_user_id])

        key = %{
          org_id: org_id,
          plane: key_row.plane,
          scopes: key_row.scopes || %{},
          minter_role: key_row.minter_role,
          # F3.4 — carry expiry so the use-time gate can also refuse an expired key
          # (defence-in-depth over the deny-on-read query).
          expires_at: Map.get(key_row, :expires_at)
        }

        actor = %{
          id: user_id,
          org_id: org_id,
          role: key_row.minter_role,
          plane: key_row.plane,
          api_key: key
        }

        {:ok, actor}

      _ ->
        :error
    end
  end

  defp fetch(source, keys) do
    Enum.find_value(keys, fn k ->
      if is_map(source) and Map.has_key?(source, k), do: Map.get(source, k)
    end)
  end
end
