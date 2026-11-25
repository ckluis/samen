defmodule PawChart.AuthSpineSessionGateTest do
  @moduledoc """
  The prod gate `PawChartWeb.Auth` (a `:browser` plug) admitted only the legacy `samen_current_user`
  session key. The framework login (`POST /login`) writes only `samen_session_token`, so an ARMED host
  redirected every real login to /login. A LIVE spine session is an authenticated principal too; an
  unknown or revoked token is not (positive control + red path).
  """
  use PawChart.DataCase, async: false

  import Plug.Conn

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias PawChart.Operator.{AuthToken, Credential, Membership, Org, Session, User}

  setup do
    prev = Application.get_env(:pawchart, :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:pawchart, :auth_required?, true)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:pawchart, :auth_required?),
        else: Application.put_env(:pawchart, :auth_required?, prev)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp gate(token) do
    Plug.Test.conn(:get, "/notifications")
    |> Plug.Test.init_test_session(%{Auth.session_token_key() => token})
    |> PawChartWeb.Auth.call([])
  end

  test "an armed host admits a LIVE spine session and refuses an unknown token" do
    {:ok, tenant} =
      Register.register(
        %{
          org_name: "Gate Clinic #{System.unique_integer([:positive])}",
          first_name: "Ada",
          last_name: "Lovelace",
          email: "gate-#{System.unique_integer([:positive])}@example.test",
          password: "correct horse battery staple"
        },
        %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: PawChart.Repo}
      )

    {:ok, _session, raw} =
      SessionCreate.create(%{session: Session, org: Org, membership: Membership, user: User}, tenant.credential.id)

    refute gate(raw).halted

    refused = gate("not-a-live-token")
    assert refused.halted
    assert get_resp_header(refused, "location") == ["/login"]
  end
end
