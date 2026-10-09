defmodule Samen.Web.ReplayPlayerTest do
  @moduledoc """
  ADR-052 §2.3 (P3) — the replay PLAYER end to end: a REAL session recorded by the P2 recorder
  over the REAL `Samen.Web.CRM.ContactsLive` and the vault-routed `Samen.WebTest.Crm.Person`
  (`full_name`, `emails`, `phones` vaulted; seeded with distinctive plaintext sentinels), played
  back through `Samen.Web.Replay.PlayerLive` on each plane.

  Like `replay_recorder_test.exs`, samen_web carries no `lazy_html`, so a connected
  `Phoenix.LiveViewTest` session cannot run: each test drives the CONNECTED player socket
  through the real `on_mount` (`Samen.Web.TenantAuthz` on the tenant plane; the operator
  identity `Samen.Web.Operator.Authz` would have assigned on the operator plane), the real
  `mount/3`, and the real batch function `show/2`, then renders `render/1` and reads the
  `srcdoc` document the player built.

  Masking watch-list (CLAUDE.md, `Samen.MaskingCase`): GREEN tenant admin + operator-with-grant
  clear; RED operator-without-grant `••••`, never plaintext, never `vt_`; SABOTAGE twin.
  Red paths R8 (plane, grant, shred, viewer-not-recorder), R9 (no session → nothing; expiry
  stops the next batch), R10 (one token-only audit row per open), tenant authz (non-admin,
  cross-org), inert rendering (no phx- binding can run).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.FeatureFlags.Cache
  alias Samen.Replay
  alias Samen.Replay.Capture
  alias Samen.Reveal.Grants
  alias Samen.Web.Replay.{Access, IndexLive, PlayerLive, Renderer}
  alias Samen.WebTest.Operator.{Membership, User}
  alias Samen.WebTest.ReplayRecording

  @operator_org "0f000000-0000-4000-8000-0000000000ee"
  @first "Aurelia"
  @last "Sentinelson"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, {:shared, self()})
    Cache.invalidate_all()

    on_exit(fn ->
      Cache.invalidate_all()
      Replay.erase_runtime_config()
      Capture.detach()
    end)

    seeded = Seeds.seed_all()
    ReplayRecording.start_capture!([seeded.org_id])
    id = ReplayRecording.record_contacts!(seeded.org_id, build_mount(:crm, []))

    %{
      seeded: seeded,
      org: seeded.org_id,
      person_id: seeded.crm.person.id,
      replay_id: id,
      operator: Ash.UUID.generate()
    }
  end

  # -- harness --------------------------------------------------------------------------

  defp sentinels, do: [@first, @last, Seeds.contact_email()]

  defp user!(org_id, role) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "viewer#{System.unique_integer([:positive])}",
        full_name: %Samen.Type.FullName{first: "Viewer", last: "Person"},
        emails: [%{address: "viewer@example.test"}]
      })
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  defp connected_socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      router: Samen.WebTest.SecurityRouter,
      endpoint: Samen.WebTest.SecurityEndpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end

  # The tenant player on the settings mount, through the REAL TenantAuthz on_mount.
  defp tenant_player(module \\ PlayerLive, org, replay_id, user_id, extra \\ %{}) do
    mount = build_mount(:settings)

    session = %{
      "samen_mount" => Samen.Web.Mount.to_session(mount),
      "samen_current_user" => user_id
    }

    params = Map.merge(%{"id" => replay_id, "org" => org}, extra)
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, connected_socket())
    {:ok, socket} = module.mount(params, session, socket)
    socket
  end

  # The operator player on the operator workspace mount, with the identity T146 assigns.
  defp operator_player(module \\ PlayerLive, org, replay_id, operator_id) do
    mount = build_operator_mount(@operator_org)
    session = %{"samen_mount" => Samen.Web.Mount.to_session(mount)}
    params = %{"org_id" => org, "id" => replay_id}
    socket = with_operator_identity(connected_socket(), operator_id)
    {:ok, socket} = module.mount(params, session, socket)
    socket
  end

  defp page(socket, module \\ PlayerLive), do: render_html(module, socket.assigns)

  defp audit_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT aud_subject_id, aud_actor_id, aud_correlation_id::text, aud_detail " <>
          "FROM aud_event WHERE aud_event_type = 'replay.viewed' ORDER BY aud_occurred_at"
      )

    rows
  end

  defp grant!(operator_id, subject_id, org) do
    {:ok, req} =
      Grants.request(%{
        subject_id: subject_id,
        requestor_id: operator_id,
        reason: "ticket 4242 replay review",
        org_id: org
      })

    {:ok, grant} = Grants.approve(req, %{granted_by: Ash.UUID.generate(), org_id: org})
    grant
  end

  # The frame that shows the listed contacts (mount → params → render: index 2).
  @list_frame 2

  defp at_list(socket), do: PlayerLive.show(socket, @list_frame)

  # -- R8 ---------------------------------------------------------------------------------

  describe "R8 — the player resolves every reference on the VIEWER's plane" do
    test "GREEN tenant admin: the referenced fields render CLEAR (current values)", ctx do
      user = user!(ctx.org, :admin)
      socket = ctx.org |> tenant_player(ctx.replay_id, user.id) |> at_list()

      assert socket.assigns.state == :open
      srcdoc = socket.assigns.frame_html
      assert is_binary(srcdoc)

      for s <- sentinels(), do: assert(srcdoc =~ s, "tenant admin should see #{s} clear")

      [name] = for r <- socket.assigns.refs, r.attribute == "full_name", do: r.outcome
      assert name == :clear
      refute srcdoc =~ "vt_"
      # The page labels the values as CURRENT.
      assert page(socket) =~ "values are CURRENT"
    end

    test "GREEN operator WITH a live reveal grant on the subject: clear through the vault chokepoint",
         ctx do
      open_impersonation!(ctx.operator, ctx.org)
      grant!(ctx.operator, ctx.person_id, ctx.org)

      socket = ctx.org |> operator_player(ctx.replay_id, ctx.operator) |> at_list()
      assert socket.assigns.state == :open
      srcdoc = socket.assigns.frame_html

      assert srcdoc =~ @first
      assert Enum.all?(socket.assigns.refs, &(&1.outcome == :clear))
      refute srcdoc =~ "vt_"
    end

    test "RED operator WITHOUT a grant: •••• in the frame, never plaintext, never a vt_ token", ctx do
      open_impersonation!(ctx.operator, ctx.org)

      socket = ctx.org |> operator_player(ctx.replay_id, ctx.operator) |> at_list()
      assert socket.assigns.state == :open

      assert_masked_dom!(socket.assigns.frame_html, sentinels())
      assert Enum.all?(socket.assigns.refs, &(&1.outcome == :masked))
      # The whole player page (srcdoc attribute included) carries no plaintext and no token.
      outer = page(socket)
      for s <- sentinels(), do: refute(outer =~ s)
      refute outer =~ "vt_"
    end

    test "SABOTAGE twin: the mask scan is refutable — the same recording flipped to the tenant plane leaks",
         ctx do
      open_impersonation!(ctx.operator, ctx.org)
      masked = ctx.org |> operator_player(ctx.replay_id, ctx.operator) |> at_list()
      user = user!(ctx.org, :admin)
      clear = ctx.org |> tenant_player(ctx.replay_id, user.id) |> at_list()

      # The ONLY difference is the viewer's plane: the recording is the same row.
      assert_masked_dom!(masked.assigns.frame_html, sentinels())
      assert_leak_detected!(clear.assigns.frame_html, @first)

      assert_raise ExUnit.AssertionError, fn ->
        assert_masked_dom!(clear.assigns.frame_html, sentinels())
      end
    end

    test "after Samen.Erasure.shred of the subject the frame shows the erased placeholder", ctx do
      user = user!(ctx.org, :admin)
      before = ctx.org |> tenant_player(ctx.replay_id, user.id) |> at_list()
      assert before.assigns.frame_html =~ @first

      {:ok, _} = Samen.Erasure.shred(ctx.person_id, repo: Repo, org_id: ctx.org)

      socket = ctx.org |> tenant_player(ctx.replay_id, user.id) |> at_list()
      srcdoc = socket.assigns.frame_html
      assert srcdoc =~ "[erased]"
      for s <- sentinels(), do: refute(srcdoc =~ s)
      assert Enum.all?(socket.assigns.refs, &(&1.outcome == :shredded))
    end

    test "a reveal grant revoked mid-playback masks the very next frame batch", ctx do
      open_impersonation!(ctx.operator, ctx.org)
      grant = grant!(ctx.operator, ctx.person_id, ctx.org)

      socket = ctx.org |> operator_player(ctx.replay_id, ctx.operator) |> at_list()
      assert socket.assigns.frame_html =~ @first

      {:ok, _} = Grants.revoke(grant.id)
      socket = PlayerLive.show(socket, @list_frame + 1)

      assert socket.assigns.state == :open
      assert_masked_dom!(socket.assigns.frame_html, sentinels())
    end
  end

  # -- R9 ---------------------------------------------------------------------------------

  describe "R9 — watching is impersonating" do
    test "no active impersonation session: denied — nothing read, nothing rendered, nothing written",
         ctx do
      socket = operator_player(ctx.org, ctx.replay_id, ctx.operator)

      assert socket.assigns.state == :denied
      assert socket.assigns.deny_reason == :no_session
      assert socket.assigns.frames == []
      assert socket.assigns.frame_html == nil
      assert audit_rows() == []

      html = page(socket)
      assert html =~ ~s(id="replay-denied")
      assert html =~ ~s(id="open-session-form")
      refute html =~ ~s(id="replay-frame")
      refute html =~ "Contacts"

      # Positive control: the same operator WITH a session is let in.
      open_impersonation!(ctx.operator, ctx.org)
      assert operator_player(ctx.org, ctx.replay_id, ctx.operator).assigns.state == :open
    end

    test "a session that ends mid-playback stops the next batch: nothing more is rendered", ctx do
      session = open_impersonation!(ctx.operator, ctx.org)
      socket = operator_player(ctx.org, ctx.replay_id, ctx.operator)
      assert socket.assigns.state == :open
      assert is_binary(socket.assigns.frame_html)

      {:ok, _} = Samen.Impersonation.close(session.id)
      socket = PlayerLive.show(socket, 1)

      assert socket.assigns.state == :stopped
      assert socket.assigns.frame_html == nil
      assert socket.assigns.frames == []
      assert socket.assigns.refs == []
      refute page(socket) =~ ~s(id="replay-frame")
      # A stopped player ignores further batches.
      assert PlayerLive.show(socket, 2).assigns.frame_html == nil
    end

    test "the dead render reads and writes nothing (the open happens on the connected mount)", ctx do
      open_impersonation!(ctx.operator, ctx.org)
      mount = build_operator_mount(@operator_org)
      session = %{"samen_mount" => Samen.Web.Mount.to_session(mount)}
      socket = with_operator_identity(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}, ctx.operator)

      {:ok, socket} = PlayerLive.mount(%{"org_id" => ctx.org, "id" => ctx.replay_id}, session, socket)
      assert socket.assigns.state == :connecting
      assert socket.assigns.frames == []
      assert audit_rows() == []
    end
  end

  # -- R10 --------------------------------------------------------------------------------

  describe "R10 — every open writes exactly one token-only aud_event" do
    test "operator: one replay.viewed row per open (ids + a bounded detail), none per frame", ctx do
      session = open_impersonation!(ctx.operator, ctx.org)
      socket = operator_player(ctx.org, ctx.replay_id, ctx.operator)

      assert [[subject, actor, correlation, detail]] = audit_rows()
      assert subject == ctx.replay_id
      assert actor == ctx.operator
      assert correlation == session.id
      assert detail == "event=replay.viewed plane=operator"

      # Stepping frames is not an open.
      socket = PlayerLive.show(socket, 1)
      _ = PlayerLive.show(socket, 3)
      assert length(audit_rows()) == 1

      # A second open is a second row.
      _ = operator_player(ctx.org, ctx.replay_id, ctx.operator)
      assert length(audit_rows()) == 2

      # Token-only: no plaintext, no reason text in the row.
      text = inspect(audit_rows())
      for s <- sentinels(), do: refute(text =~ s)
      refute text =~ "ticket"
    end

    test "tenant admin: one row, the principal as actor, no impersonation correlation", ctx do
      user = user!(ctx.org, :admin)
      _ = tenant_player(ctx.org, ctx.replay_id, user.id)
      assert [[subject, actor, nil, "event=replay.viewed plane=tenant"]] = audit_rows()
      assert subject == ctx.replay_id
      assert actor == user.id
    end
  end

  # -- tenant authz ------------------------------------------------------------------------

  describe "tenant plane: only an admin-class member of the SAME org" do
    test "a non-admin member is denied: nothing read, nothing written", ctx do
      member = user!(ctx.org, :member)
      socket = tenant_player(ctx.org, ctx.replay_id, member.id)

      assert socket.assigns.state == :denied
      assert socket.assigns.deny_reason == :not_admin
      assert socket.assigns.frames == []
      assert audit_rows() == []
      refute page(socket) =~ ~s(id="replay-frame")

      # Positive control: an owner is admin-class.
      owner = user!(ctx.org, :owner)
      assert tenant_player(ctx.org, ctx.replay_id, owner.id).assigns.state == :open
    end

    test "a cross-org admin is denied: by the pinned org set (armed) and by membership (disarmed)",
         ctx do
      other = Ash.UUID.generate()
      admin_elsewhere = user!(other, :admin)

      # Disarmed: `?org=` names the victim org, but the principal holds no membership there.
      socket = tenant_player(ctx.org, ctx.replay_id, admin_elsewhere.id)
      assert socket.assigns.deny_reason == :not_admin

      # Armed: the principal's pinned authorized org set excludes the victim org.
      pinned = %{
        assigns: %{
          samen_mount: build_mount(:settings),
          samen_authorized_orgs: [other]
        }
      }

      assert Access.authorize(pinned, ctx.org, admin_elsewhere.id) == {:error, :cross_org}
      assert {:ok, _} = Access.authorize(pinned, other, admin_elsewhere.id)

      # In its OWN org that admin cannot load this org's replay (OrgScope on the session).
      socket = tenant_player(other, ctx.replay_id, admin_elsewhere.id)
      assert socket.assigns.state == :not_found
      assert audit_rows() == []
    end

    test "fail closed: no org, no plane, no pinned org set" do
      admin_org = Ash.UUID.generate()
      admin = user!(admin_org, :admin)
      settings = build_mount(:settings)

      # Positive control: the same admin, mount and org with an org set is let in.
      assert {:ok, %{plane: :tenant, viewer_id: viewer}} =
               Access.authorize(%{assigns: %{samen_mount: settings, samen_authorized_orgs: :unconstrained}}, admin_org, admin.id)

      assert viewer == admin.id

      assert Access.authorize(%{assigns: %{samen_mount: settings, samen_authorized_orgs: :unconstrained}}, nil, admin.id) ==
               {:error, :no_org}

      # No pinned org set at all (never produced by TenantAuthz) → not this org.
      assert Access.authorize(%{assigns: %{samen_mount: settings}}, admin_org, admin.id) == {:error, :cross_org}
      # No mount, or an aggregate mount → no plane to watch on.
      assert Access.authorize(%{assigns: %{samen_authorized_orgs: :unconstrained}}, admin_org, admin.id) ==
               {:error, :no_plane}

      aggregate = %{settings | scope_kind: :aggregate}

      assert Access.authorize(%{assigns: %{samen_mount: aggregate, samen_authorized_orgs: :unconstrained}}, admin_org, admin.id) ==
               {:error, :no_plane}

      # No principal → not an admin.
      assert Access.authorize(%{assigns: %{samen_mount: settings, samen_authorized_orgs: :unconstrained}}, admin_org, nil) ==
               {:error, :not_admin}
    end

    test "an operator-plane (impersonated) settings mount is refused — operators watch from the console",
         ctx do
      user = user!(ctx.org, :admin)

      socket = %{
        assigns: %{
          samen_mount: build_mount(:settings, plane: :operator, target_org_id: ctx.org),
          samen_authorized_orgs: :unconstrained
        }
      }

      assert Access.authorize(socket, ctx.org, user.id) == {:error, :operator_plane}
      assert Access.authorize(socket, "not-an-org", user.id) == {:error, :no_org}
    end
  end

  # -- inert rendering -----------------------------------------------------------------------

  describe "rendering has no side effects" do
    test "the srcdoc has no phx- binding and no script; the iframe sandbox forbids scripts", ctx do
      user = user!(ctx.org, :admin)
      socket = ctx.org |> tenant_player(ctx.replay_id, user.id) |> at_list()
      srcdoc = socket.assigns.frame_html

      # Positive control: the recorded view's own render IS full of bindings.
      view_mount = socket.assigns.view_mount
      assert %Samen.Web.Mount{scope_kind: :crm} = view_mount
      %{value: raw_assigns} = Samen.Replay.Player.resolve(Samen.Replay.Player.assigns_at(socket.assigns.frames, @list_frame), %Samen.Scope{actor: %{org_id: ctx.org, plane: :tenant}})
      raw = render_html(Samen.Web.CRM.ContactsLive, Map.put(raw_assigns, :samen_mount, view_mount))
      assert raw =~ "phx-"

      refute srcdoc =~ "phx-"
      refute srcdoc =~ ~r/<script/i
      assert srcdoc =~ "default-src 'none'"

      html = page(socket)
      [iframe] = Regex.run(~r/<iframe[^>]*id="replay-frame"[^>]*>/, html)
      assert iframe =~ ~s(sandbox="")
      refute iframe =~ "allow-scripts"
      refute iframe =~ "allow-same-origin"
    end

    test "inert/1 strips bindings, handlers and scripts from rendered HTML" do
      html =
        ~S|<div phx-click="delete" phx-value-id="1" onclick="x()">ok on file</div>| <>
          ~S|<script>alert(1)</script><a href="javascript:void(0)" phx-hook="H">a</a>|

      out = Renderer.inert(html)
      refute out =~ "phx-"
      refute out =~ "onclick"
      refute out =~ "<script"
      refute out =~ "javascript:"
      # Text is untouched.
      assert out =~ "ok on file"
    end

    test "a frame whose template raises shows a placeholder for that frame and playback continues",
         ctx do
      user = user!(ctx.org, :admin)
      socket = tenant_player(ctx.org, ctx.replay_id, user.id)
      # The last frames hold the new-contact FORM, which the recorder dropped (a form is
      # never captured): today's template cannot render that frame.
      last = length(socket.assigns.frames) - 1
      socket = PlayerLive.show(socket, last)
      assert socket.assigns.state == :open
      assert socket.assigns.frame_html == nil
      assert socket.assigns.frame_error == :render_failed
      assert page(socket) =~ ~s(id="replay-frame-placeholder")

      assert is_binary(PlayerLive.show(socket, @list_frame).assigns.frame_html)
    end

    test "the player itself is never recorded", ctx do
      user = user!(ctx.org, :admin)
      mount = build_mount(:settings)
      session = %{"samen_mount" => Samen.Web.Mount.to_session(mount), "samen_current_user" => user.id}
      params = %{"id" => ctx.replay_id, "org" => ctx.org}
      {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, connected_socket())

      # Positive control: the tenant on_mount DID attach the recorder to the player's socket.
      assert socket.private[:samen_replay][:state] == :pending
      assert Enum.any?(socket.private.lifecycle.after_render, &(&1.id == :samen_replay))

      {:ok, socket} = PlayerLive.mount(params, session, socket)
      assert socket.private[:samen_replay][:state] == :off
      refute Enum.any?(socket.private.lifecycle.after_render, &(&1.id == :samen_replay))
    end
  end

  # -- listing -------------------------------------------------------------------------------

  describe "listing replays" do
    test "authorized like an open; bounded metadata only; writes no audit row", ctx do
      # Operator without a session: denied, nothing listed.
      socket = operator_player(IndexLive, ctx.org, nil, ctx.operator)
      assert socket.assigns.state == :denied
      assert socket.assigns.sessions == []

      open_impersonation!(ctx.operator, ctx.org)
      socket = operator_player(IndexLive, ctx.org, nil, ctx.operator)
      assert [%{id: id, view_short: "ContactsLive", drift: :same}] = socket.assigns.sessions
      assert id == ctx.replay_id

      html = page(socket, IndexLive)
      assert html =~ "/operator/replays/#{ctx.org}/#{ctx.replay_id}"
      for s <- sentinels(), do: refute(html =~ s)
      assert audit_rows() == []

      member = user!(ctx.org, :member)
      assert tenant_player(IndexLive, ctx.org, nil, member.id).assigns.state == :denied
      admin = user!(ctx.org, :admin)
      assert [%{id: ^id}] = tenant_player(IndexLive, ctx.org, nil, admin.id).assigns.sessions
    end
  end

  # -- framework mount -----------------------------------------------------------------------

  describe "framework mount (≈0 authored LOC)" do
    test "the settings and operator macros declare the replay routes behind their gates" do
      assert {"/settings/replays", IndexLive} in Samen.Web.Router.__routes__(:settings, "/settings")
      assert {"/settings/replays/:id", PlayerLive} in Samen.Web.Router.__routes__(:settings, "/settings")

      routes = Phoenix.Router.routes(Samen.WebTest.FleetCockpitRouter)

      for path <- ["/operator/replays/:org_id", "/operator/replays/:org_id/:id"] do
        route = Enum.find(routes, &(&1.path == path))
        assert route, "expected #{path} from samen_operator_routes/2"
        {_view, _action, _opts, live_session} = route.metadata.phoenix_live_view
        hooks = Enum.map(live_session.extra[:on_mount] || [], fn %{id: id} -> id; other -> other end)
        assert {Samen.Web.Operator.Authz, :require_operator} in hooks
      end
    end
  end
end
