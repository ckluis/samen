defmodule Samen.Web.Auth.AccountControllerTest do
  @moduledoc """
  T110 — the no-JS HTTP POST fallbacks for the pre-actor identity arc, and the
  SECURITY INVARIANT that motivated the escalation: **no credential ever appears
  in a URL / query string.**

  The escalation (persona-1 F1): Samen ships zero client JS, so `/signup`'s
  `phx-submit`-only form degraded to a native **GET**, putting the plaintext
  password in the URL (`?registration[password]=…`). The fix pairs each pre-actor
  GET LiveView with a real POST controller action (`Samen.Web.Auth.AccountController`),
  the same `SessionController` precedent login/2FA already use.

  Proven here:

    1. Each POST action performs the REAL server-side mutation (register /
       request-reset / reset / accept-invite) — the LiveView is not trusted.
    2. Every redirect Location carries only NON-secret status flags — never the
       submitted password/token (the invariant, asserted per action).
    3. The router pairs a `post(...)` route with each pre-actor GET `live(...)`
       (the structural gap F1 identified — the route-table proof).
    4. Every credential/token-bearing arc FORM renders `method="post"` + a real
       `action` — with a POSITIVE CONTROL (the pre-fix `phx-submit`-only shape)
       proving the check actually fails against the old markup (anti-tautology,
       `Samen.RedPath` discipline).
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Conn

  require Ash.Query

  alias Samen.Identity.Register
  alias Samen.Web.Auth.AccountController
  alias Samen.Web.Auth.InviteAcceptLive
  alias Samen.Web.Auth.RegistrationLive
  alias Samen.Web.Auth.ResetLive
  alias Samen.Web.Auth.ResetRequestLive
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Invitations
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  @secret_key_base String.duplicate("a", 64)
  @strong_password "correct horse battery staple"

  # The invite step's real send goes through the fail-honest Delivery chokepoint;
  # point it at the test LocalSink so `Invitations.create/4` captures instead of
  # returning `{:error, :adapter_unconfigured}` (the invitation_test posture).
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

  # A real host router mounting the pre-actor auth arc via the macro — if the
  # macro fails to emit the paired POST routes, THIS MODULE FAILS TO COMPILE
  # and the route-table test below fails (the `Samen.Web.RouterTest` proof).
  defmodule HostRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_auth_routes(namespace: Samen.WebTest.Operator, repo: Samen.WebTest.Repo)
    end
  end

  defp mount, do: Mount.new(:auth, Samen.WebTest.Operator, Repo)

  defp unique_email, do: "acct-#{System.unique_integer([:positive])}@example.test"

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp register!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_name: "Acct Co #{System.unique_integer([:positive])}",
          first_name: "Ada",
          last_name: "Lovelace",
          email: unique_email(),
          password: @strong_password
        },
        overrides
      )

    {:ok, result} = Register.register(attrs, register_mods())
    # `Register.register/2`'s result map carries no `:email`; expose the attr the
    # test supplied (for URL-leak assertions + downstream lookups).
    Map.put(result, :email, attrs.email)
  end

  defp arc_conn(method, path, private) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    Plug.Test.conn(method, path)
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Map.put(:remote_ip, {203, 0, 113, 5})
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> then(fn c -> Enum.reduce(private, c, fn {k, v}, acc -> put_private(acc, k, v) end) end)
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  defp find_org(name), do: Org |> Ash.Query.filter(name == ^name) |> Ash.read!(authorize?: false)

  # The invariant checker: within the form whose id is `form_id`, is there a real
  # `method="post"` AND a non-empty `action=` (so a native no-JS submit is a POST
  # to a real endpoint, never a credential-leaking GET)?
  defp post_form?(html, form_id) do
    case Regex.run(~r/<form[^>]*\bid="#{form_id}"[^>]*>/, html) do
      [tag] -> tag =~ ~s(method="post") and tag =~ ~r/action="[^"]+"/
      _ -> false
    end
  end

  # ===========================================================================
  # register/2 — A1
  # ===========================================================================

  describe "AccountController.register/2 (POST /signup)" do
    test "creates the org+user and redirects with ?registered=1 — the password NEVER in the URL" do
      name = "URL Leak Guard #{System.unique_integer([:positive])}"

      params = %{
        "org_name" => name,
        "first_name" => "Grace",
        "last_name" => "Hopper",
        "email" => unique_email(),
        "password" => @strong_password
      }

      conn =
        arc_conn(:post, "/signup", %{samen_mount: mount(), samen_signup_path: "/signup"})
        |> AccountController.register(%{"registration" => params})

      assert location(conn) == "/signup?registered=1"
      # THE INVARIANT: the plaintext password is nowhere in the redirect target.
      refute location(conn) =~ @strong_password
      refute location(conn) =~ "password"
      # The mutation was real.
      assert [_org] = find_org(name)
    end

    test "a duplicate email is the SAME ?registered=1 outcome (no account-existence oracle)" do
      existing = register!()

      params = %{
        "org_name" => "Dup #{System.unique_integer([:positive])}",
        "email" => existing.email,
        "password" => @strong_password
      }

      conn =
        arc_conn(:post, "/signup", %{samen_mount: mount(), samen_signup_path: "/signup"})
        |> AccountController.register(%{"registration" => params})

      assert location(conn) == "/signup?registered=1"
    end

    test "a weak password redirects with ?error=weak_password and creates NOTHING" do
      name = "Weak #{System.unique_integer([:positive])}"
      params = %{"org_name" => name, "email" => unique_email(), "password" => "short"}

      conn =
        arc_conn(:post, "/signup", %{samen_mount: mount(), samen_signup_path: "/signup"})
        |> AccountController.register(%{"registration" => params})

      assert location(conn) == "/signup?error=weak_password"
      assert find_org(name) == []
    end
  end

  # ===========================================================================
  # request_reset/2 + reset/2 — A3
  # ===========================================================================

  describe "AccountController password reset (POST /reset, POST /reset/:token)" do
    test "request_reset always redirects to the uniform ?requested=1 — the email is never in the URL" do
      result = register!()

      conn =
        arc_conn(:post, "/reset", %{samen_mount: mount(), samen_reset_path: "/reset"})
        |> AccountController.request_reset(%{"reset" => %{"email" => result.email}})

      assert location(conn) == "/reset?requested=1"
      refute location(conn) =~ result.email
    end

    test "a real reset consume redirects with ?reset=1 and rehashes — the new password NEVER in the URL" do
      result = register!()
      {:ok, _auth_token, raw_token} = Samen.Auth.TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)
      new_password = "a whole different passphrase entirely"

      conn =
        arc_conn(:post, "/reset/#{raw_token}", %{samen_mount: mount(), samen_reset_path: "/reset"})
        |> AccountController.reset(%{"token" => raw_token, "reset" => %{"password" => new_password}})

      assert location(conn) == "/reset/#{raw_token}?reset=1"
      refute location(conn) =~ new_password
      refute location(conn) =~ "passphrase"

      # The consume was real: the token is now single-use spent.
      conn2 =
        arc_conn(:post, "/reset/#{raw_token}", %{samen_mount: mount(), samen_reset_path: "/reset"})
        |> AccountController.reset(%{"token" => raw_token, "reset" => %{"password" => "yet another strong one"}})

      assert location(conn2) == "/reset/#{raw_token}?error=invalid_token"
    end

    test "a weak reset password redirects with ?error=weak_password (token untouched)" do
      result = register!()
      {:ok, _auth_token, raw_token} = Samen.Auth.TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)

      conn =
        arc_conn(:post, "/reset/#{raw_token}", %{samen_mount: mount(), samen_reset_path: "/reset"})
        |> AccountController.reset(%{"token" => raw_token, "reset" => %{"password" => "short"}})

      assert location(conn) == "/reset/#{raw_token}?error=weak_password"
    end
  end

  # ===========================================================================
  # accept_invite/2 — A5
  # ===========================================================================

  describe "AccountController.accept_invite/2 (POST /invite/:token)" do
    test "a needs-registration accept joins the org and redirects ?joined=1 — the password NEVER in the URL" do
      owner = register!()
      invited_email = unique_email()

      owner_scope = %Samen.Scope{
        actor: %{
          id: owner.user.id,
          org_id: owner.org.id,
          role: :owner,
          kind: :tenant,
          plane: :tenant,
          verified?: true
        }
      }

      settings_mount = Mount.new(:settings, Samen.WebTest.Operator, Repo)
      {:ok, invitation, raw_token} = Invitations.create(settings_mount, owner_scope, invited_email, "member")
      assert invitation.status == "pending"

      join_password = "brand new teammate passphrase"

      conn =
        arc_conn(:post, "/invite/#{raw_token}", %{samen_mount: mount(), samen_invite_path: "/invite"})
        |> AccountController.accept_invite(%{"token" => raw_token, "accept" => %{"password" => join_password}})

      assert location(conn) == "/invite/#{raw_token}?joined=1"
      refute location(conn) =~ join_password
      refute location(conn) =~ "passphrase"

      # The join was real: a membership now exists in the org for the new user.
      memberships =
        Membership
        |> Ash.Query.filter(org_id == ^owner.org.id)
        |> Ash.read!(authorize?: false)

      assert length(memberships) == 2
    end

    test "a weak join password redirects with ?error=weak_password" do
      owner = register!()

      owner_scope = %Samen.Scope{
        actor: %{id: owner.user.id, org_id: owner.org.id, role: :owner, kind: :tenant, plane: :tenant, verified?: true}
      }

      settings_mount = Mount.new(:settings, Samen.WebTest.Operator, Repo)
      {:ok, _invitation, raw_token} = Invitations.create(settings_mount, owner_scope, unique_email(), "member")

      conn =
        arc_conn(:post, "/invite/#{raw_token}", %{samen_mount: mount(), samen_invite_path: "/invite"})
        |> AccountController.accept_invite(%{"token" => raw_token, "accept" => %{"password" => "short"}})

      assert location(conn) == "/invite/#{raw_token}?error=weak_password"
    end
  end

  # ===========================================================================
  # THE INVARIANT — route table + rendered form shape (with positive control)
  # ===========================================================================

  describe "T110 invariant — the router pairs a POST route with each pre-actor GET LiveView" do
    test "samen_auth_routes emits post(...) for /signup, /reset, /reset/:token, /invite/:token" do
      routes = HostRouter.__routes__()

      for path <- ["/signup", "/reset", "/reset/:token", "/invite/:token"] do
        assert Enum.any?(routes, &(&1.verb == :post and &1.path == path)),
               "expected a POST route for #{path} (the no-JS credential-safe fallback), found none"

        # anti-tautology: the paired GET live route must ALSO exist.
        assert Enum.any?(routes, &(&1.verb == :get and &1.path == path)),
               "expected the paired GET live route for #{path}"
      end
    end
  end

  describe "T110 invariant — every credential/token arc form renders method=post + a real action" do
    test "GREEN: signup / reset / reset-token / invite forms are all POST with an action" do
      m = build_mount(:auth)

      reg = mount_smoke(RegistrationLive, m)
      assert reg =~ ~s(type="password")
      assert post_form?(reg, "registration-form")

      req = mount_smoke(ResetRequestLive, m)
      assert post_form?(req, "reset-request-form")

      result = register!()
      {:ok, _t, raw} = Samen.Auth.TokenMint.mint(AuthToken, result.credential.id, :password_reset, nil, 3600)
      rst = mount_smoke(ResetLive, m, %{"token" => raw})
      assert rst =~ ~s(type="password")
      assert post_form?(rst, "reset-form")

      owner = register!()

      owner_scope = %Samen.Scope{
        actor: %{id: owner.user.id, org_id: owner.org.id, role: :owner, kind: :tenant, plane: :tenant, verified?: true}
      }

      {:ok, _inv, invite_raw} =
        Invitations.create(Mount.new(:settings, Samen.WebTest.Operator, Repo), owner_scope, unique_email(), "member")

      inv = mount_smoke(InviteAcceptLive, m, %{"token" => invite_raw})
      assert inv =~ ~s(type="password")
      assert post_form?(inv, "invite-accept-form")
    end

    test "POSITIVE CONTROL: the checker REJECTS the pre-fix `phx-submit`-only shape (proves it can fail)" do
      # The EXACT shape persona-1 F1 captured: a password form with only
      # `phx-submit` — no `method`, no `action` — which a no-JS browser submits
      # as a native GET, leaking `registration[password]=…` into the URL.
      pre_fix = ~s(<form id="registration-form" phx-submit="register"><input type="password" name="registration[password]"></form>)

      refute post_form?(pre_fix, "registration-form"),
             "the checker must FLAG the pre-fix GET form — otherwise it is a tautology that could never catch the regression"

      # And the SAME checker passes once the real POST attrs are present.
      fixed = ~s(<form id="registration-form" action="/signup" method="post" phx-submit="register"><input type="password"></form>)
      assert post_form?(fixed, "registration-form")
    end
  end
end
