defmodule Driftwood.AuthProdPathTest do
  @moduledoc """
  F2 (ADR-031) — the launch auth on-ramp: the prod path derives the tenant actor from an
  authenticated session, NOT a query param. Green / red / sabotage-twin proofs of the
  fail-closed actor-derivation gate + the day-1 login mechanism.

  The sabotage twin is committed at `scripts/sabotages/17-f2-authn-actor-gate-bypass.patch`
  (flips `Samen.Web.CurrentOrg`'s `authn_required?` to always-false); the two `prod-path RED`
  tests below MUST fail under it and pass on the restored tree (anti-tautology).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_session: 2, get_resp_header: 2]

  alias Samen.Web.{CurrentOrg, Mount}

  @org_a "aaaaaaaa-0000-4000-8000-00000000000a"
  @org_b "bbbbbbbb-0000-4000-8000-00000000000b"
  @user "11111111-0000-4000-8000-000000000011"
  @email "alice@blueridge.test"
  @password "correct horse battery"

  # The mount EXACTLY as `DriftwoodWeb.Router` builds it for a tenant/shared surface: the
  # authn + authorized_orgs seams on the labels, over Driftwood's CRM namespace.
  defp router_mount do
    Mount.new(:crm, Driftwood.Crm, Driftwood.Repo,
      labels: %{
        default_org_id: @org_a,
        authn: {:app_env, :driftwood, :auth_required?},
        authorized_orgs: {Driftwood.Auth, :authorized_org_ids, []}
      }
    )
  end

  defp arm_auth! do
    salt = "unit-test-salt"

    creds = %{
      @email => %{
        user_id: @user,
        org_ids: [@org_a],
        salt: salt,
        pbkdf2: Driftwood.Auth.hash(@password, salt)
      }
    }

    Application.put_env(:driftwood, :auth_credentials, creds)
    Application.put_env(:driftwood, :auth_required?, true)

    on_exit(fn ->
      Application.put_env(:driftwood, :auth_credentials, %{})
      Application.put_env(:driftwood, :auth_required?, false)
    end)
  end

  # ==========================================================================
  # The actor-derivation gate (the security boundary)
  # ==========================================================================

  describe "prod path (auth armed) — CurrentOrg.resolve/3" do
    setup do
      arm_auth!()
      {:ok, mount: router_mount()}
    end

    test "GREEN: an authenticated member derives an actor for their own org", %{mount: mount} do
      session = %{"samen_current_user" => @user}

      assert CurrentOrg.resolve(mount, %{}, session) == @org_a
      # And the built actor is scoped to that org.
      assert Mount.scope(mount, @org_a).actor.org_id == @org_a
    end

    test "prod-path RED: an unauthenticated request derives NO actor", %{mount: mount} do
      # Even WITH a ?org= param and a session-org, no authenticated principal => nil (no actor).
      assert CurrentOrg.resolve(mount, %{"org" => @org_a}, %{}) == nil
      assert CurrentOrg.resolve(mount, %{}, %{"samen_current_org" => @org_a}) == nil
    end

    test "prod-path RED: an authenticated user cannot act on a non-member org", %{mount: mount} do
      session = %{"samen_current_user" => @user}

      # ?org=<org_b> is NOT in alice's authorized set — she lands on her OWN org, never org_b.
      resolved = CurrentOrg.resolve(mount, %{"org" => @org_b}, session)
      assert resolved == @org_a
      refute resolved == @org_b
    end

    test "RED: an authenticated principal with NO provisioned org derives no actor", %{mount: mount} do
      session = %{"samen_current_user" => "99999999-0000-4000-8000-000000000099"}
      assert CurrentOrg.resolve(mount, %{"org" => @org_a}, session) == nil
    end
  end

  # ==========================================================================
  # The dev/test convenience path stays intact (auth NOT armed)
  # ==========================================================================

  test "CONVENIENCE: with auth disabled, a ?org= param still resolves (dogfood identity)" do
    # auth_required? defaults false in test — the query-param convenience is retained.
    refute DriftwoodWeb.Auth.auth_required?()
    mount = router_mount()
    assert CurrentOrg.resolve(mount, %{"org" => @org_b}, %{}) == @org_b
  end

  # ==========================================================================
  # Day-1 login mechanism (Driftwood.Auth verifier + DriftwoodWeb.Auth session)
  # ==========================================================================

  describe "BYO-auth verifier + session establishment" do
    setup do
      arm_auth!()
      :ok
    end

    test "GREEN: correct credentials verify and yield the user + authorized orgs" do
      assert {:ok, @user, [@org_a]} = Driftwood.Auth.verify(@email, @password)
    end

    test "RED: a wrong password does NOT verify" do
      assert :error = Driftwood.Auth.verify(@email, "wrong")
    end

    test "RED: an unknown email does NOT verify" do
      assert :error = Driftwood.Auth.verify("nobody@nowhere.test", @password)
    end

    test "log_in_user establishes the framework principal + sticky org in the session" do
      conn =
        conn(:post, "/login")
        |> init_test_session(%{})
        |> DriftwoodWeb.Auth.log_in_user(@user, @org_a)

      assert get_session(conn, "samen_current_user") == @user
      assert get_session(conn, CurrentOrg.session_key()) == @org_a
    end
  end

  # ==========================================================================
  # The conn-level gate (defense-in-depth over the actor gate)
  # ==========================================================================

  describe "DriftwoodWeb.Auth plug" do
    test "prod: an unauthenticated request to a guarded path is redirected to /login" do
      arm_auth!()

      conn =
        conn(:get, "/crm/contacts")
        |> init_test_session(%{})
        |> DriftwoodWeb.Auth.call([])

      assert conn.halted
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "prod: /login itself is exempt (no redirect loop)" do
      arm_auth!()

      conn =
        conn(:get, "/login")
        |> init_test_session(%{})
        |> DriftwoodWeb.Auth.call([])

      refute conn.halted
    end

    test "prod: an authenticated request passes the gate" do
      arm_auth!()

      conn =
        conn(:get, "/crm/contacts")
        |> init_test_session(%{"samen_current_user" => @user})
        |> DriftwoodWeb.Auth.call([])

      refute conn.halted
    end

    test "dev/test: the gate is a no-op when auth is not required" do
      conn =
        conn(:get, "/crm/contacts")
        |> init_test_session(%{})
        |> DriftwoodWeb.Auth.call([])

      refute conn.halted
    end
  end
end
