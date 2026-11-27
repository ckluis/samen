defmodule Samen.Web.TenantRoleSettingsTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Settings and onboarding: the API keys, invitations, reveal approvals and
  security pages and the onboarding wizard act with the role the signed-in person's ACTIVE membership resolves to
  (`Samen.Web.TenantActor`); their lists and membership lookups read as that person, never as `Plane.scope/2`'s fixed
  `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`). Every refusal is
  paired with a positive control.

  Role choice: the pages are readable by every active member; minting and revoking an API key, inviting and revoking an
  invitation, deciding a reveal request and every write of the onboarding wizard are an admin's, checked by the handler
  itself and offered to an admin only. The security page reads the person's own account and writes nothing.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint Samen.WebTest.SecurityEndpoint

  alias Samen.Web.Onboarding.WizardLive
  alias Samen.Web.Settings.{ApiKeysLive, InvitationsLive, RevealApprovalsLive, SecurityLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  setup do
    H.setup_accounts()
  end

  defp html(view, socket), do: render_html(view, socket.assigns)

  defp pages do
    [
      {ApiKeysLive, "/settings/api-keys"},
      {InvitationsLive, "/settings/invitations"},
      {RevealApprovalsLive, "/settings/reveal-approvals"},
      {SecurityLive, "/settings/security"},
      {WizardLive, "/onboarding"}
    ]
  end

  # Mount, then the route's `handle_params` (these pages load there too).
  defp page(login, view, path, org_id) do
    H.params(view, H.live_socket(login, view, path, org_id), %{})
  end

  test "every page acts with the RESOLVED role, not :member", ctx do
    for role <- [:viewer, :member, :admin, :owner], {view, path} <- pages() do
      socket = page(H.log_in(Map.fetch!(ctx, role)), view, path, ctx.org_id)
      assert socket.assigns.actor_state == :ok, inspect(view)
      assert socket.assigns.acting_scope.actor.role == role, "#{inspect(view)} acted as #{socket.assigns.acting_scope.actor.role}, not #{role}"
      assert socket.assigns.acting_scope.actor.resolved == true
      refute String.starts_with?(socket.assigns.acting_scope.actor.id, "broker:")
    end
  end

  test "NAVIGATION: a suspended admin's pages are the denied state: nothing is read, no event writes", ctx do
    login = H.log_in(ctx.admin)
    sockets = for {view, path} <- pages(), do: {view, page(login, view, path, ctx.org_id)}

    # something to read while acting (vacuous control): an API key the admin mints
    {_, keys_socket} = Enum.find(sockets, &(elem(&1, 0) == ApiKeysLive))
    minted = H.event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, keys_socket)
    assert length(minted.assigns.keys) == 1

    SpineAccounts.suspend!(ctx.admin, ctx.org_id)

    for {view, socket} <- sockets do
      refused = H.params(view, socket, %{})
      assert refused.assigns.actor_state == :denied, inspect(view)
      assert refused.assigns.acting_scope == nil
      assert html(view, refused) =~ ~s(id="actor-denied"), inspect(view)
    end

    # nothing a refused page offers writes
    refused = H.params(ApiKeysLive, minted, %{})
    assert H.event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, refused).assigns == refused.assigns
    assert refused.assigns.keys == []
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for {view, path} <- pages() do
      socket = page(login, view, path, ctx.org_id) |> H.break_identity()
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(view, socket, %{}) end)
      assert refused.assigns.actor_state == :unavailable, inspect(view)
      assert html(view, refused) =~ ~s(id="actor-unavailable"), inspect(view)
    end
  end

  test "api keys: only an admin is offered the form; a viewer's and a member's crafted mint creates nothing, an admin's does", ctx do
    path = "/settings/api-keys"

    for role <- [:viewer, :member] do
      socket = page(H.log_in(Map.fetch!(ctx, role)), ApiKeysLive, path, ctx.org_id)
      assert socket.assigns.can_admin == false
      refute html(ApiKeysLive, socket) =~ ~s(id="api-key-mint-form")
      socket = H.event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, socket)
      assert socket.assigns.mint_error =~ "admin role required"
      assert socket.assigns.minted_key == nil
    end

    admin = page(H.log_in(ctx.admin), ApiKeysLive, path, ctx.org_id)
    assert html(ApiKeysLive, admin) =~ ~s(id="api-key-mint-form")
    admin = H.event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, admin)
    assert admin.assigns.mint_error == nil
    assert admin.assigns.minted_key != nil
    assert length(admin.assigns.keys) == 1

    # a member's crafted revoke of that key leaves it live; the admin's revokes it
    [key] = admin.assigns.keys
    member = page(H.log_in(ctx.member), ApiKeysLive, path, ctx.org_id)
    assert length(member.assigns.keys) == 1, "reads are open to a member"
    member = H.event(ApiKeysLive, "revoke", %{"id" => key.id}, member)
    assert member.assigns.mint_error =~ "admin role required"
    refute hd(member.assigns.keys).revoked?
    admin = H.event(ApiKeysLive, "revoke", %{"id" => key.id}, admin)
    assert hd(admin.assigns.keys).revoked?
  end

  test "api keys: an admin demoted while the page is open mints nothing at the next event; an unchanged admin does", ctx do
    path = "/settings/api-keys"
    open = H.open_socket(H.log_in(ctx.admin), ApiKeysLive, path, ctx.org_id)
    assert open.assigns.can_admin

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, open)
    assert demoted.assigns.acting_scope.actor.role == :member
    refute demoted.assigns.can_admin
    assert demoted.assigns.minted_key == nil

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :admin)
    fresh = H.open_socket(H.log_in(ctx.admin), ApiKeysLive, path, ctx.org_id)
    fresh = H.live_event(ApiKeysLive, "mint", %{"key" => %{"read" => "1"}}, fresh)
    assert fresh.assigns.minted_key != nil
  end

  test "invitations: only an admin is offered the form; a member's crafted invite sends nothing, an admin's reaches the invite", ctx do
    path = "/settings/invitations"
    params = %{"invitation" => %{"email" => "new-hire-#{System.unique_integer([:positive])}@example.test", "role" => "member"}}

    for role <- [:viewer, :member] do
      socket = page(H.log_in(Map.fetch!(ctx, role)), InvitationsLive, path, ctx.org_id)
      assert socket.assigns.can_admin == false
      refute html(InvitationsLive, socket) =~ ~s(id="invite-form")
      socket = H.event(InvitationsLive, "invite", params, socket)
      assert socket.assigns.invite_error =~ "admin role required"
      assert socket.assigns.invited_raw_token == nil
    end

    # the inviter's account is a verified one (the invite's capability gate): confirm the owner's address
    {:ok, _} =
      Samen.Identity.Confirm.consume(ctx.owner.raw_verify_token, %{
        credential: Samen.WebTest.Operator.Credential,
        auth_token: Samen.WebTest.Operator.AuthToken,
        repo: Samen.WebTest.Repo
      })

    admin = page(H.log_in(ctx.owner), InvitationsLive, path, ctx.org_id)
    assert html(InvitationsLive, admin) =~ ~s(id="invite-form")
    admin = H.event(InvitationsLive, "invite", params, admin)
    assert is_binary(admin.assigns.invited_raw_token), "the owner's invite was sent (positive control): #{inspect(admin.assigns.invite_error)}"
  end

  test "invitations: an invite acts as the person the role was resolved for, not as a stale session user id", ctx do
    {:ok, _} =
      Samen.Identity.Confirm.consume(ctx.owner.raw_verify_token, %{
        credential: Samen.WebTest.Operator.Credential,
        auth_token: Samen.WebTest.Operator.AuthToken,
        repo: Samen.WebTest.Repo
      })

    params = %{"invitation" => %{"email" => "stale-id-#{System.unique_integer([:positive])}@example.test", "role" => "member"}}
    owner = page(H.log_in(ctx.owner), InvitationsLive, "/settings/invitations", ctx.org_id)
    assert owner.assigns.acting_scope.actor.id == owner.assigns.user_id, "the page starts out consistent"

    # the page's separately read user id now names somebody else (a viewer): the invite still runs as the owner
    stale = Phoenix.Component.assign(owner, :user_id, ctx.viewer.user.id)
    stale = H.event(InvitationsLive, "invite", params, stale)
    assert is_binary(stale.assigns.invited_raw_token), "the owner's invite was sent as the owner: #{inspect(stale.assigns.invite_error)}"
  end

  test "reveal approvals: only an admin may decide; a member's crafted decision is refused at the role, an admin's passes the role gate", ctx do
    path = "/settings/reveal-approvals"

    for role <- [:viewer, :member] do
      socket = page(H.log_in(Map.fetch!(ctx, role)), RevealApprovalsLive, path, ctx.org_id)
      assert socket.assigns.can_approve? == false
      socket = H.event(RevealApprovalsLive, "approve", %{"request" => Ash.UUID.generate()}, socket)
      assert socket.assigns.decision_notice =~ "admin role is required"
    end

    admin = page(H.log_in(ctx.admin), RevealApprovalsLive, path, ctx.org_id)
    assert admin.assigns.can_approve? == true
    admin = H.event(RevealApprovalsLive, "approve", %{"request" => Ash.UUID.generate()}, admin)
    assert admin.assigns.decision_notice =~ "not in this org's pending queue", "the admin reached the queue check (positive control)"
  end

  test "reveal approvals: an admin demoted while the page is open decides nothing at the next event", ctx do
    open = H.open_socket(H.log_in(ctx.admin), RevealApprovalsLive, "/settings/reveal-approvals", ctx.org_id)
    assert open.assigns.can_approve?

    SpineAccounts.set_role!(ctx.admin, ctx.org_id, :member)
    demoted = H.live_event(RevealApprovalsLive, "approve", %{"request" => Ash.UUID.generate()}, open)
    assert demoted.assigns.decision_notice =~ "admin role is required"
  end

  test "the security page is read-only for every role and reads the person's own account", ctx do
    for role <- [:viewer, :member, :admin, :owner] do
      socket = page(H.log_in(Map.fetch!(ctx, role)), SecurityLive, "/settings/security", ctx.org_id)
      out = html(SecurityLive, socket)
      assert out =~ "Security" and socket.assigns.actor_state == :ok
      refute out =~ ~s(id="actor-denied")
    end
  end

  test "the wizard: every write is an admin's; a member's crafted name and finish change nothing, an admin's do", ctx do
    path = "/onboarding"
    name = %{"org" => %{"name" => "Renamed By A Member"}}

    member = page(H.log_in(ctx.member), WizardLive, path, ctx.org_id)
    member = H.event(WizardLive, "name_org", name, member)
    assert member.assigns.org_error =~ "admin"
    refute member.assigns.step == :plan
    member = H.event(WizardLive, "finish", %{}, member)
    assert member.assigns.invite_error =~ "admin"
    refute member.assigns.complete?

    admin = page(H.log_in(ctx.admin), WizardLive, path, ctx.org_id)
    admin = H.event(WizardLive, "name_org", %{"org" => %{"name" => "Renamed By An Admin"}}, admin)
    assert admin.assigns.step == :plan, "the admin's rename was accepted (positive control): #{inspect(admin.assigns.org_error)}"
  end

  test "the wizard's no-JS POST: a member's name_org changes nothing, an admin's does", ctx do
    org_name = fn -> Ash.get!(Samen.WebTest.Operator.Org, ctx.org_id, authorize?: false).name end
    before = org_name.()
    params = fn name -> %{"org" => %{"name" => name}, "org_id" => ctx.org_id} end

    member = H.log_in(ctx.member)
    conn = post(member.conn, "/onboarding/name_org", params.("Renamed By A Member"))
    assert redirected_to(conn) =~ "error=1"
    assert org_name.() == before

    admin = H.log_in(ctx.admin)
    conn = post(admin.conn, "/onboarding/name_org", params.("Renamed By An Admin"))
    refute redirected_to(conn) =~ "error=1"
    assert org_name.() == "Renamed By An Admin"
  end

  test "the wizard controller refuses a member itself: Onboarding.* is never reached, an admin's POST reaches it", ctx do
    # The kernel would refuse the member as well, so the answer alone cannot tell who refused: trace the calls instead.
    # A process cannot be traced by itself and the endpoint serves the request in its own process, so a collector traces all.
    traced = [{Samen.Web.Onboarding, :name_org, 4}, {Samen.Web.Onboarding, :select_plan, 4}, {Samen.Web.Onboarding, :complete!, 3}]
    Code.ensure_loaded!(Samen.Web.Onboarding)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    collector =
      spawn_link(fn ->
        loop = fn loop ->
          receive do
            {:trace, _pid, :call, {Samen.Web.Onboarding, fun, _args}} -> Agent.update(calls, &[fun | &1])
            {:flush, from, ref} -> send(from, {:flushed, ref})
          end

          loop.(loop)
        end

        loop.(loop)
      end)

    :erlang.trace(:all, true, [:call, {:tracer, collector}])
    Enum.each(traced, fn {m, f, a} -> :erlang.trace_pattern({m, f, a}, true, [:global]) end)

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      Enum.each(traced, fn {m, f, a} -> :erlang.trace_pattern({m, f, a}, false, [:global]) end)
    end)

    reached = fn ->
      ref = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, _, ^ref} -> :ok
      end

      ref = make_ref()
      send(collector, {:flush, self(), ref})

      receive do
        {:flushed, ^ref} -> Agent.get_and_update(calls, &{&1, []})
      end
    end

    posts = [
      {"/onboarding/name_org", %{"org" => %{"name" => "Controller Refusal"}, "org_id" => ctx.org_id}, :name_org},
      {"/onboarding/plan", %{"plan" => %{"key" => "free"}, "org_id" => ctx.org_id}, :select_plan},
      {"/onboarding/finish", %{"org_id" => ctx.org_id}, :complete!}
    ]

    member = H.log_in(ctx.member)

    for {path, params, _fun} <- posts do
      conn = post(member.conn, path, params)
      assert redirected_to(conn) =~ "error=1"
    end

    assert reached.() == [], "a member's POST must be refused by the controller before Onboarding.* runs"

    admin = H.log_in(ctx.admin)

    for {path, params, _fun} <- posts, do: post(admin.conn, path, params)

    assert Enum.sort(reached.()) == Enum.sort(for {_, _, fun} <- posts, do: fun),
           "an admin's POSTs reach Onboarding.* (positive control)"
  end
end
