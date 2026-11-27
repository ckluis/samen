defmodule Samen.Web.TenantRoleReadsTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), the read-only pages: the own-org analytics page and the ⌘K search page act
  with the role the signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Plane.scope/2`'s
  fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.

  Role choice: both pages only read, so every active member acts (a viewer searches and reads). The analytics read keeps its
  own rank gate (`AnalyticsReads.can_query?/1`: admin and member), which now judges the REAL role.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Search.SearchLive
  alias Samen.Web.Tenant.AnalyticsLive
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    H.setup_accounts()
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  defp pages do
    [
      %{name: "AnalyticsLive", view: AnalyticsLive, path: "/analytics", events: [{"retry_load", %{}}]},
      %{name: "SearchLive", view: SearchLive, path: "/search", events: [{"search", %{"q" => "zebra"}}, {"retry_search", %{}}]}
    ]
  end

  test "every page acts with the RESOLVED role, not :member", ctx do
    logins = for who <- [:viewer, :member, :admin, :owner], into: %{}, do: {who, H.log_in(Map.fetch!(ctx, who))}

    for page <- pages(), role <- [:viewer, :member, :admin, :owner] do
      socket = H.live_socket(Map.fetch!(logins, role), page.view, page.path, ctx.org_id)
      assert socket.assigns.actor_state == :ok, page.name
      assert socket.assigns.acting_scope.actor.role == role, "#{page.name} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "a viewer reads: search answers and analytics renders its empty state (the role gate judges the real role)", ctx do
    viewer = H.log_in(ctx.viewer)

    search = H.live_socket(viewer, SearchLive, "/search", ctx.org_id)
    search = H.event(SearchLive, "search", %{"q" => "zebra"}, search)
    assert search.assigns.search_error == nil
    assert search.assigns.results == []

    analytics = H.live_socket(viewer, AnalyticsLive, "/analytics", ctx.org_id)
    assert analytics.assigns.load_error == nil
    assert html(AnalyticsLive, analytics) =~ "analytics-empty"
  end

  test "the analytics role gate: an owner, an admin and a member may query; a viewer may not", ctx do
    gate = fn who ->
      socket = H.live_socket(H.log_in(Map.fetch!(ctx, who)), AnalyticsLive, "/analytics", ctx.org_id)
      Samen.Web.Tenant.AnalyticsReads.can_query?(socket.assigns.acting_scope)
    end

    assert Enum.all?([:owner, :admin, :member], gate)
    refute gate.(:viewer)
  end

  test "NAVIGATION: a suspended member's page is the denied state: nothing is read, no event reads", ctx do
    login = H.log_in(ctx.member)
    sockets = for page <- pages(), do: {page, H.live_socket(login, page.view, page.path, ctx.org_id)}

    # positive control: while acting the page renders its own state, not the refusal
    for {page, socket} <- sockets, do: refute(html(page.view, socket) =~ ~s(id="actor-denied"), page.name)

    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    for {page, socket} <- sockets do
      refused = H.params(page.view, socket, %{})
      assert refused.assigns.actor_state == :denied, page.name
      assert refused.assigns.acting_scope == nil, page.name
      assert html(page.view, refused) =~ ~s(id="actor-denied"), page.name

      for {name, p} <- page.events do
        assert H.event(page.view, name, p, refused).assigns == refused.assigns, "#{page.name} #{name} changed the refused page"
      end
    end
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for page <- pages() do
      socket = H.live_socket(login, page.view, page.path, ctx.org_id) |> H.break_identity()
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(page.view, socket, %{}) end)
      assert refused.assigns.actor_state == :unavailable, page.name
      assert html(page.view, refused) =~ ~s(id="actor-unavailable"), page.name
    end
  end

  test "OPEN PAGE: a member suspended while Search is open is refused at the next event; an unchanged member is not", ctx do
    open = H.open_socket(H.log_in(ctx.member), SearchLive, "/search", ctx.org_id)
    searched = H.live_event(SearchLive, "search", %{"q" => "zebra"}, open)
    assert searched.assigns.actor_state == :ok
    assert searched.assigns.q == "zebra"

    SpineAccounts.suspend!(ctx.member, ctx.org_id)
    gone = H.live_event(SearchLive, "search", %{"q" => "yak"}, searched)
    assert gone.assigns.actor_state == :denied
    assert gone.assigns.q == "zebra", "the refused page did not run the new search"
    assert gone.assigns.results == []
  end
end
