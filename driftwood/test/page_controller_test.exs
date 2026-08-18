defmodule DriftwoodWeb.PageControllerTest do
  @moduledoc """
  PP-7 (Batch 3 NAV-REACHABILITY, W3 BLOCKER-1) — `DriftwoodWeb.PageController.index/2`'s
  landing DECISION.

  Before this fix `/` redirected UNCONDITIONALLY to `/operator/accounts`: a fresh tenant
  who signed up, verified, and logged in (with no `return_to` — the ordinary case) landed
  on the SaaS's own cross-tenant operator console with no path into the product they just
  signed up for. `index/2` now asks "does this signed-in principal hold a REAL per-org
  `Identity.Membership` (well, a `User` row, the seam `Samen.Auth.OrgActor` reads) under
  this namespace?" via the SAME framework Identity-spine seam
  `Samen.Web.Auth.resolve_principal/2` + `Samen.Auth.OrgActor.authorized_org_ids/2` that
  `Samen.Web.CurrentOrg` already uses to derive the tenant actor elsewhere — a genuine
  tenant lands on `/broker`; anyone else (no session, or a session that resolves to NO
  tenant User anywhere — the operator's own principal) falls through UNCHANGED to the
  pre-existing operator-console landing. This is a landing/routing test, not an
  authorization test — no gate (`Samen.Web.AuthGate`, `Samen.Web.Operator.Authz`,
  `Samen.Web.CurrentOrg.resolve/3`'s fail-closed armed-host path) is touched or weakened.
  """
  use Driftwood.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Register
  alias Samen.Web.Auth

  alias Driftwood.Operator.AuthToken
  alias Driftwood.Operator.Credential
  alias Driftwood.Operator.Membership
  alias Driftwood.Operator.Org
  alias Driftwood.Operator.Session
  alias Driftwood.Operator.User

  @secret_key_base String.duplicate("b", 64)

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Driftwood.Repo}

  defp session_create_mods, do: %{session: Session, org: Org, membership: Membership, user: User}

  defp unique_email, do: "pp7-landing-#{System.unique_integer([:positive])}@example.test"

  defp register_tenant! do
    attrs = %{
      org_name: "PP-7 Landing Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result
  end

  # A minimal conn with the session plug installed (mirrors samen_web's
  # `session_test.exs` harness) — this exercises `PageController.index/2` DIRECTLY,
  # exactly as `Samen.Web.Auth.SessionController` is exercised without booting an
  # Endpoint in the sibling samen_web suite.
  defp base_conn do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(:get, "/")
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  defp signed_in_conn(raw_token), do: base_conn() |> Auth.put_session_token(raw_token)

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  test "GREEN: a fresh tenant (a real per-org User/Membership) lands on their own workspace" do
    tenant = register_tenant!()
    {:ok, _session, raw} = SessionCreate.create(session_create_mods(), tenant.credential.id)

    conn = signed_in_conn(raw) |> DriftwoodWeb.PageController.index(%{})

    assert conn.status in 300..399
    assert location(conn) == "/broker?org=#{tenant.org.id}"
    refute location(conn) == "/operator/accounts"
  end

  test "CONTROL: an anonymous visitor still lands on the operator console (unchanged)" do
    conn = base_conn() |> DriftwoodWeb.PageController.index(%{})

    assert conn.status in 300..399
    assert location(conn) == "/operator/accounts"
  end

  test "CONTROL: a signed-in principal with NO tenant User anywhere still lands on the operator console" do
    # A live, spine-resolvable session whose credential holds no `User` row under this
    # namespace at all (the shape the operator's own principal has, since operators are
    # never provisioned a `Driftwood.Operator.User`/Membership — they authenticate via the
    # separate `Driftwood.Auth` roster seam) — the landing decision must fall through
    # UNCHANGED, never crash, never invent a tenant landing for a non-tenant.
    tenant = register_tenant!()
    Ash.destroy!(tenant.membership, authorize?: false)
    Ash.destroy!(tenant.user, authorize?: false)

    {:ok, _session, raw} = SessionCreate.create(session_create_mods(), tenant.credential.id)

    conn = signed_in_conn(raw) |> DriftwoodWeb.PageController.index(%{})

    assert conn.status in 300..399
    assert location(conn) == "/operator/accounts"
  end

  test "CONTROL: an expired/unknown session token falls through to the operator console (never raises)" do
    conn = signed_in_conn("not-a-real-token") |> DriftwoodWeb.PageController.index(%{})

    assert conn.status in 300..399
    assert location(conn) == "/operator/accounts"
  end
end
