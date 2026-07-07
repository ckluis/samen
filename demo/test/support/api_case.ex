defmodule Demo.ApiCase do
  @moduledoc """
  Test helpers for the public JSON:API (T3.11). Seeds orgs / PII-bearing rows /
  api_keys (the two classes) and drives `DemoWeb.Api.Endpoint` via `Plug.Test`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import Demo.ApiCase
      alias Demo.Repo
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Demo.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Demo.Repo, {:shared, self()})
    :ok
  end

  # --- seeding -------------------------------------------------------------

  def mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  def mk_contact(org_id, attrs \\ %{}) do
    base = %{
      display_name: Map.get(attrs, :display_name, "Contact"),
      org_id: org_id,
      full_name: Map.get(attrs, :full_name, %{first: "Alice", last: "Smith"}),
      emails: Map.get(attrs, :emails, ["alice@example.com"]),
      dob: Map.get(attrs, :dob, ~D[1990-01-01])
    }

    {:ok, contact} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, base)
      |> Ash.create(authorize?: false)

    contact
  end

  def mk_user(org_id, handle, attrs \\ %{}) do
    {:ok, user} =
      Demo.Identity.User
      |> Ash.Changeset.for_create(:create, %{
        handle: handle,
        org_id: org_id,
        full_name: Map.get(attrs, :full_name, %{first: handle, last: "L"}),
        emails: Map.get(attrs, :emails, ["#{handle}@example.com"])
      })
      |> Ash.create(authorize?: false)

    user
  end

  def mk_membership(org_id, user_id, role \\ :admin) do
    {:ok, mbr} =
      Demo.Identity.Membership
      |> Ash.Changeset.for_create(:create, %{role: role, org_id: org_id, user_id: user_id})
      |> Ash.create(authorize?: false)

    mbr
  end

  @doc """
  Mint an api_key and return `{raw_key, key_row}`. `plane` is `:tenant | :operator`.
  Creates a backing user + membership in `org_id` so the auth resolver can load the
  minter's org boundary.
  """
  def mk_api_key(org_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, :tenant)
    minter_role = Keyword.get(opts, :minter_role, :admin)
    scopes = Keyword.get(opts, :scopes, %{"crm" => ["read"], "identity" => ["read"]})

    user = mk_user(org_id, "keymaster-#{System.unique_integer([:positive])}")
    mbr = mk_membership(org_id, user.id, minter_role)

    raw = "sk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    digest = DemoWeb.Api.KeyAuthPlug.digest(raw)

    {:ok, key} =
      Demo.Identity.ApiKey
      |> Ash.Changeset.for_create(:create, %{
        plane: plane,
        scopes: scopes,
        minter_role: minter_role,
        org_id: org_id,
        membership_id: mbr.id
      })
      # token_digest is public?: false (a credential digest, not tenant input), so it
      # is not accepted by `create: :*`. Force-change it as the mint step would.
      |> Ash.Changeset.force_change_attribute(:token_digest, digest)
      |> Ash.create(authorize?: false)

    {raw, key}
  end

  # --- driving -------------------------------------------------------------

  @doc """
  GET the versioned public API at `/api/v1<path>` (JSON:API), optionally with a
  bearer `key`. Drives the real top-level `DemoWeb.Router` so the `/api/v1` prefix is
  exercised end-to-end (the external contract a tenant integrates against).
  """
  def api_get(path, key \\ nil) do
    conn =
      Plug.Test.conn(:get, "/api/v1" <> path)
      |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")

    conn = if key, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> key), else: conn

    DemoWeb.Router.call(conn, DemoWeb.Router.init([]))
  end

  @doc "Decode a JSON:API response body to a map."
  def json(conn), do: Jason.decode!(conn.resp_body)
end
