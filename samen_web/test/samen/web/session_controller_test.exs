defmodule Samen.Web.SessionControllerTest do
  @moduledoc """
  The framework SESSION-write endpoint (ADR-013 §4.3). Proves `put_current_org/2` writes the
  session current org, redirects to a sanitized same-origin `return_to`, and refuses an
  off-site redirect (no open-redirect).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Samen.Web.CurrentOrg
  alias Samen.Web.SessionController

  # A minimal conn with the session plug installed, as the host :browser pipeline provides.
  defp session_conn(method \\ :get, path \\ "/") do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
  end

  test "put_current_org/2 writes the session current org and redirects to return_to" do
    conn =
      session_conn()
      |> SessionController.put_current_org(%{"org_id" => "ORG-123", "return_to" => "/billing/invoices"})

    assert get_session(conn, CurrentOrg.session_key()) == "ORG-123"
    assert redirected_to(conn) == "/billing/invoices"
  end

  test "put_current_org/2 falls back to /crm/contacts when return_to is missing" do
    conn = session_conn() |> SessionController.put_current_org(%{"org_id" => "ORG-123"})
    assert redirected_to(conn) == "/crm/contacts"
  end

  test "put_current_org/2 refuses an off-site (open-redirect) return_to" do
    conn =
      session_conn()
      |> SessionController.put_current_org(%{"org_id" => "ORG-123", "return_to" => "https://evil.example/x"})

    # The absolute URL is rejected → the safe default is used (no bounce off-site).
    assert redirected_to(conn) == "/crm/contacts"
    # The session current org is still written (the choice is honored; only the redirect is sanitized).
    assert get_session(conn, CurrentOrg.session_key()) == "ORG-123"
  end

  test "put_current_org/2 refuses a scheme-relative //host return_to" do
    conn =
      session_conn()
      |> SessionController.put_current_org(%{"org_id" => "ORG-123", "return_to" => "//evil.example/x"})

    assert redirected_to(conn) == "/crm/contacts"
  end

  defp redirected_to(conn) do
    assert conn.status in 300..399
    conn |> get_resp_header("location") |> List.first()
  end
end
