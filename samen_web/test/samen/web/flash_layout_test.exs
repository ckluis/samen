defmodule Samen.Web.FlashLayoutTest do
  @moduledoc """
  Audit-kit F07 — no component rendered `@flash`, so every `put_flash` in the product was
  invisible and a dropped socket looked like a frozen page. The fix renders both notices ONCE,
  from the LiveView layout every framework `live_session` now carries
  (`layout: {Samen.Web.Layouts, :app}`).

  Driven through the REAL router macros (`Samen.WebTest.SecurityEndpoint`), not a hand-built
  component call, so removing the `layout:` option from a macro flips these tests. Paired with a
  positive control: a request with NO flash renders no flash markup.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  setup do
    SecurityHost.disarm!()
    on_exit(fn -> SecurityHost.arm!() end)
    %{org: Ash.UUID.generate()}
  end

  defp with_flash(conn, flash), do: Plug.Conn.put_private(conn, :phoenix_flash, flash)

  test "a flash set before a LiveView page is visible on the dead render, as role=alert", %{org: org} do
    html =
      build_conn()
      |> with_flash(%{"error" => "Driver not found"})
      |> get("/crm/dashboard?org=#{org}")
      |> html_response(200)

    assert html =~ "Driver not found"
    assert html =~ ~s(role="alert")
    assert html =~ ~s(class="flash flash-error")
    # exactly once: the dead-render root layout must not render it a second time
    assert length(String.split(html, "Driver not found")) == 2
  end

  test "POSITIVE CONTROL — with no flash there is no flash markup (the test above can fail)", %{org: org} do
    html = build_conn() |> get("/crm/dashboard?org=#{org}") |> html_response(200)

    refute html =~ ~s(class="flash)
    refute html =~ ~s(id="flash-group")
    # the connection banner is in the page (hidden) so a later disconnect can show it
    assert html =~ ~s(id="connection-banner")
    assert html =~ "phx-disconnected"
    assert html =~ "hidden"
  end

  test "EVERY live route of the security router (tenant + settings + flags + ai + analytics) carries the layout" do
    live_routes =
      Samen.WebTest.SecurityRouter.__routes__()
      |> Enum.filter(&match?(%{metadata: %{phoenix_live_view: _}}, &1))

    assert length(live_routes) > 10, "the router must expose the live routes this test is about"

    for %{path: path, metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}} <- live_routes do
      assert get_in(live_session, [:extra, :layout]) == {Samen.Web.Layouts, :app},
             "#{path} is not rendered inside Samen.Web.Layouts.app/1, so its put_flash would be invisible"
    end
  end

  test "an unsafe flash key (a hand-over secret) is never displayed", %{org: org} do
    html =
      build_conn()
      |> with_flash(%{"totp_recovery_codes" => "AAAA-1111", "info" => "ok"})
      |> get("/crm/dashboard?org=#{org}")
      |> html_response(200)

    assert html =~ "ok"
    refute html =~ "AAAA-1111"
  end
end
