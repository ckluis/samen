defmodule Driftwood.ApiCase do
  @moduledoc """
  F1 (Gate-5 carry) — test helpers for the freight public JSON:API. Seeds a brokerage org
  + a PII-bearing driver + a `Driftwood.Freight.ApiKey` (the two classes), and drives the
  `DriftwoodWeb.Api.Endpoint` pipeline (key-auth → AshJsonApi router) via `Plug.Test`.

  Requests are driven against the AshJsonApi endpoint with the FULL `/api/v1/…` request
  path (the AshJsonApi router carries `prefix: "/api/v1"` and matches on the request
  path), so the versioned external contract a tenant integrates against is exercised
  end-to-end.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import Driftwood.ApiCase
      alias Driftwood.Repo
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Driftwood.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Driftwood.Repo, {:shared, self()})
    :ok = Driftwood.NonPiiSetup.register_all()
    :ok
  end

  # --- seeding -------------------------------------------------------------

  def mk_org, do: Ecto.UUID.generate()

  @doc """
  Seed a driver in `org_id`. `cdl` defaults to a recognizable plaintext CDL so the
  masked/clear assertions are unambiguous.
  """
  def mk_driver(org_id, attrs \\ %{}) do
    base = %{
      org_id: org_id,
      full_name: Map.get(attrs, :full_name, %{first: "Dana", last: "Driver"}),
      cdl_number: Map.get(attrs, :cdl_number, "CDL-CLEAR-#{System.unique_integer([:positive])}"),
      cdl_state: "TX",
      cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
      medical_card_expiry: Date.add(Date.utc_today(), 180),
      eld_provider: :samsara,
      status: :available
    }

    {:ok, driver} =
      Driftwood.Freight.Driver
      |> Ash.Changeset.for_create(:create, base)
      |> Ash.create(authorize?: false)

    driver
  end

  @doc """
  Mint an api_key and return `{raw_key, key_row}`. `plane` is `:tenant | :operator`.
  """
  def mk_api_key(org_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, :tenant)
    minter_role = Keyword.get(opts, :minter_role, :admin)
    scopes = Keyword.get(opts, :scopes, %{"freight" => ["read"]})

    raw = "sk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    digest = DriftwoodWeb.Api.KeyAuthPlug.digest(raw)

    {:ok, key} =
      Driftwood.Freight.ApiKey
      |> Ash.Changeset.for_create(:create, %{
        plane: plane,
        scopes: scopes,
        minter_role: minter_role,
        minter_user_id: "user-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Ash.Changeset.force_change_attribute(:token_digest, digest)
      |> Ash.create(authorize?: false)

    {raw, key}
  end

  # --- driving -------------------------------------------------------------

  @doc """
  GET the versioned public API at `/api/v1<path>` (JSON:API), optionally with a bearer
  `key`. Drives the `DriftwoodWeb.Api.Endpoint` pipeline (key-auth → AshJsonApi router).
  """
  def api_get(path, key \\ nil) do
    conn =
      Plug.Test.conn(:get, "/api/v1" <> path)
      |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")

    conn = if key, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> key), else: conn

    # Simulate the top-level router's `forward("/api/v1", …)`: it STRIPS the `/api/v1`
    # prefix into `script_name` before the AshJsonApi endpoint sees the request, so the
    # AshJsonApi router (prefix "/api/v1") matches the declared route (`/drivers`). This
    # exercises the SAME endpoint pipeline (key-auth → AshJsonApi) a real forwarded
    # request hits; `request_path` still carries the full `/api/v1/…` external contract.
    segments = String.split(path, "/", trim: true)
    conn = %{conn | script_name: ["api", "v1"], path_info: segments}

    DriftwoodWeb.Api.Endpoint.call(conn, DriftwoodWeb.Api.Endpoint.init([]))
  end

  @doc "Decode a JSON:API response body to a map."
  def json(conn), do: Jason.decode!(conn.resp_body)
end
