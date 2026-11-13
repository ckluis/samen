defmodule Samen.Web.ReadsHonestFailureReviewTest do
  @moduledoc """
  Review follow-ups to `ReadsHonestFailureP2Test`: a REAL data-layer failure (a table that is gone,
  not the `inject_read_faults` seam) must reach the screen as outage copy and never as denial copy;
  a real denial must keep its denial copy; and client-chosen malformed ids are "not found", not an
  error log and not an outage.

  Postgres DDL is transactional, so renaming a table inside the sandbox transaction is a faithful
  and self-undoing outage.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, person_id: seeded.crm.person.id}
  end

  defp break_table!(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME TO zz_gone_#{table}")
  end

  defp admin_scope(org_id, role \\ :admin),
    do: %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: true}}

  # ===========================================================================
  # N1 — a malformed client id is "not found"
  # ===========================================================================

  describe "N1 — malformed ids" do
    alias Samen.Web.Notifications.Reads
    alias Samen.Web.ObjectRef

    test "mark_read with a non-UUID id is :not_found, logs nothing; a real id still marks read", %{org_id: org_id} do
      mount = build_mount(:notifications)
      scope = Mount.scope(mount, org_id)

      {:ok, notification} =
        Samen.Notifications.Engine.notify(
          %{org_id: org_id, recipient_id: Ash.UUID.generate(), event_type: "crm.person.flagged", channel: :in_app, rendered_body: "n1"},
          notification_module: Samen.WebTest.Primitives.Notification,
          preference_module: Samen.WebTest.Primitives.NotificationPreference,
          repo: Samen.WebTest.Repo
        )

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Reads.mark_read(mount, scope, "not-a-uuid")
          assert {:error, :not_found} = Reads.mark_read(mount, scope, "")
        end)

      assert log == ""

      # POSITIVE CONTROL: the same call with the real id works (so the :not_found above is the cast).
      assert :ok = Reads.mark_read(mount, scope, notification.id)
    end

    test "ObjectRef.resolve with a non-UUID id is :not_found (an inert chip), never :unavailable or an error log",
         %{org_id: org_id, person_id: person_id} do
      mount = build_mount(:crm)
      scope = Mount.scope(mount, org_id)

      log =
        capture_log(fn ->
          assert {:error, :not_found} = ObjectRef.resolve(mount, scope, %ObjectRef{key: "crm.person", id: "not-a-uuid", raw: "x"})
        end)

      assert log == ""

      # POSITIVE CONTROL: a real id resolves; a genuine failure is still :unavailable.
      ref = %ObjectRef{key: "crm.person", id: person_id, raw: "x"}
      assert {:ok, _card} = ObjectRef.resolve(mount, scope, ref)
      inject_read_faults([:object_ref_load])
      {result, _log} = with_log(fn -> ObjectRef.resolve(mount, scope, ref) end)
      assert result == {:error, :unavailable}
    end
  end

  # ===========================================================================
  # N2 / S1 — flags: denial copy for a denial, outage copy for an outage
  # ===========================================================================

  describe "N2 — flags write copy" do
    alias Samen.Web.Flags.Reads
    alias Samen.WebTest.Primitives.FeatureFlag

    defp seed_flag!(org_id) do
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "review.flag", enabled: true, rollout_pct: 100}, authorize?: false)
      |> Ash.create!()
    end

    test "a member (not admin) toggling a flag is a DENIAL: denial copy, flag unchanged" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)

      assert {:error, copy} = Reads.toggle_flag(mount, admin_scope(org_id, :member), flag.id)
      assert copy =~ "don't have permission"
      refute copy =~ "couldn't save"
      assert Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled

      # POSITIVE CONTROL: the admin's identical call goes through.
      assert {:ok, _} = Reads.toggle_flag(mount, admin_scope(org_id, :admin), flag.id)
      refute Ash.get!(FeatureFlag, flag.id, authorize?: false).enabled
    end

    test "a REAL outage (the table is gone) is outage copy, never denial copy" do
      org_id = Ash.UUID.generate()
      flag = seed_flag!(org_id)
      mount = build_mount(:flags)
      break_table!(FeatureFlag)

      {result, log} = with_log(fn -> Reads.toggle_flag(mount, admin_scope(org_id), flag.id) end)
      assert {:error, copy} = result
      assert copy =~ "couldn't save this flag change right now"
      refute copy =~ "permission"
      assert log =~ "failed"
      refute log =~ "zz_gone"
    end
  end

  # ===========================================================================
  # S3 / S4 — onboarding wizard
  # ===========================================================================

  describe "S3/S4 — onboarding wizard" do
    alias Samen.Web.Onboarding.{WizardController, WizardLive}
    alias Samen.WebTest.Operator.{Invitation, Membership, Org, User}

    setup do
      prev = Application.get_env(:samen_core, :delivery_env)
      Application.put_env(:samen_core, :delivery_env, :test)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, :delivery_env, prev),
          else: Application.delete_env(:samen_core, :delivery_env)
      end)

      org_id = Ash.UUID.generate()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "wiz-#{System.unique_integer([:positive])}", full_name: %Samen.Type.FullName{first: "Wiz", last: "Admin"}})
        |> Ash.create!(authorize?: false)

      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin})
      |> Ash.create!(authorize?: false)

      %{wiz_org: org_id, wiz_user: user.id}
    end

    defp wizard_socket(ctx) do
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(
        samen_mount: build_mount(:settings),
        samen_acting_as: false,
        return_to: nil,
        org_id: ctx.wiz_org,
        user_id: ctx.wiz_user,
        samen_session: %{},
        invite_error: nil,
        invited_raw_token: nil,
        step: :invite
      )
    end

    defp wizard_invite(ctx) do
      {:noreply, socket} =
        WizardLive.handle_event("invite", %{"invitation" => %{"email" => "wiz-new@example.com", "role" => "member"}}, wizard_socket(ctx))

      socket
    end

    test "invite: a failed MEMBERSHIP lookup says 'couldn't send', not 'No membership in context'", ctx do
      # POSITIVE CONTROL first: the healthy path mints a token and shows no error.
      healthy = wizard_invite(ctx)
      assert is_binary(healthy.assigns.invited_raw_token)
      assert healthy.assigns.invite_error == nil

      # And a genuinely missing membership keeps the 'no membership' copy.
      missing = wizard_invite(%{ctx | wiz_user: Ash.UUID.generate()})
      assert missing.assigns.invite_error =~ "No membership in context"

      break_table!(Membership)
      {socket, _log} = with_log(fn -> wizard_invite(ctx) end)

      assert socket.assigns.invite_error =~ "Nothing was sent"
      refute socket.assigns.invite_error =~ "No membership in context"
      refute socket.assigns.invite_error =~ "refused"
      assert socket.assigns.invited_raw_token == nil
    end

    test "invite: a failed WRITE (a real outage) says 'nothing was sent', never 'Invite refused (admin role required…)'", ctx do
      break_table!(Invitation)
      {socket, log} = with_log(fn -> wizard_invite(ctx) end)

      assert socket.assigns.invite_error =~ "Couldn't send that invitation right now. Nothing was sent"
      refute socket.assigns.invite_error =~ "refused"
      assert socket.assigns.invited_raw_token == nil
      assert log =~ "write failed write=settings_invitation_create"
    end

    test "invite: a real REFUSAL (a member cannot invite) keeps the refusal copy", ctx do
      member =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: ctx.wiz_org, handle: "wiz-member", full_name: %Samen.Type.FullName{first: "M", last: "Ember"}})
        |> Ash.create!(authorize?: false)

      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: ctx.wiz_org, user_id: member.id, role: :member})
      |> Ash.create!(authorize?: false)

      socket = wizard_invite(%{ctx | wiz_user: member.id})
      assert socket.assigns.invite_error =~ "Invite refused"
      refute socket.assigns.invite_error =~ "Nothing was sent"
    end

    test "the no-JS controller redirects an outage to the 'nothing was sent' flag, and the wizard renders that copy", ctx do
      invite_conn = fn ->
        Plug.Test.conn(:post, "/onboarding/invite")
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_private(:samen_mount, build_mount(:settings))
        |> WizardController.invite(%{
          "org_id" => ctx.wiz_org,
          "user_id" => ctx.wiz_user,
          "invitation" => %{"email" => "wiz-conn@example.com", "role" => "member"}
        })
      end

      # POSITIVE CONTROL: healthy → the invited flag.
      assert Phoenix.ConnTest.redirected_to(invite_conn.()) =~ "invited=1"

      break_table!(Invitation)
      {conn, _log} = with_log(fn -> invite_conn.() end)
      location = Phoenix.ConnTest.redirected_to(conn)
      assert location =~ "invite_error=unavailable"

      socket = wizard_socket(ctx)
      {:noreply, socket} = WizardLive.handle_params(%{"invite_error" => "unavailable", "org" => ctx.wiz_org}, "http://x/onboarding", socket)
      assert socket.assigns.invite_error =~ "Nothing was sent"
    end

    test "S4: 'You're all set' is derived from the ONE org read — the load issues a single org query", _ctx do
      mount = build_mount(:settings)

      {:ok, reg} =
        Samen.Identity.Register.register(
          %{
            org_name: "Review Co #{System.unique_integer([:positive])}",
            first_name: "Ada",
            last_name: "Lovelace",
            email: "review-#{System.unique_integer([:positive])}@example.test",
            password: "correct horse battery staple"
          },
          %{org: Org, credential: Samen.WebTest.Operator.Credential, user: User, membership: Membership, auth_token: Samen.WebTest.Operator.AuthToken, repo: Samen.WebTest.Repo}
        )

      org_id = reg.org.id
      table = AshPostgres.DataLayer.Info.table(Org)
      prefix = Keyword.get(Samen.WebTest.Repo.config(), :telemetry_prefix, [:samen, :web_test, :repo]) ++ [:query]
      counter = :counters.new(1, [])
      handler = "org-reads-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        prefix,
        fn _event, _m, %{query: query}, {counter, table} ->
          if String.contains?(query, ~s(FROM "#{table}")), do: :counters.add(counter, 1, 1)
        end,
        {counter, table}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(samen_mount: mount, samen_acting_as: false, return_to: nil)
        |> then(&WizardLive.load(&1, org_id, nil))

      assert :counters.get(counter, 1) == 1
      assert socket.assigns.complete? == false

      # Completing flips it: the same single read now says complete.
      owner = %Samen.Scope{actor: %{id: reg.user.id, org_id: org_id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}}
      {:ok, _} = Samen.Web.Onboarding.complete!(mount, owner, org_id)

      done =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(samen_mount: mount, samen_acting_as: false, return_to: nil)
        |> then(&WizardLive.load(&1, org_id, nil))

      assert done.assigns.complete? == true
    end
  end

  # ===========================================================================
  # S5 / S6 — AI support drafts: decided structurally, never from error text
  # ===========================================================================

  describe "S5/S6 — AI support drafts" do
    alias Samen.Web.AI.{Server, SupportDraftLive}
    alias Samen.Web.Reads.Adoption

    @draft Samen.AI.SupportReplyDraft

    defp ai_mount do
      Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: %{ai_crm_resource: Samen.WebTest.Crm.Person})
    end

    # The draft resource's repo (`SamenCore.TestRepo`) is NOT started in samen_web: a REAL not-adopted
    # host. Listing it in `:ecto_repos` models the other real condition — an ADOPTING host whose
    # repo is configured but down. Same repo, same resource; the configuration alone flips the answer.
    defp configure_repo!(repo) do
      previous = Application.get_env(:samen_web, :ecto_repos)
      Application.put_env(:samen_web, :ecto_repos, [Samen.WebTest.Repo, repo])
      on_exit(fn -> Application.put_env(:samen_web, :ecto_repos, previous) end)
    end

    defp compose(org_id) do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(samen_mount: ai_mount(), samen_acting_as: false)
        |> then(&SupportDraftLive.load(&1, org_id))

      {:noreply, socket} =
        SupportDraftLive.handle_event("compose", %{"to_subscriber_id" => Ash.UUID.generate(), "instruction" => "hi"}, socket)

      {socket, render_html(SupportDraftLive, socket.assigns)}
    end

    test "REAL not-adopted host: list is the documented honest empty and says so ONCE; compose says 'not adopted'", %{org_id: org_id} do
      Adoption.forget_logged(@draft)
      on_exit(fn -> Adoption.forget_logged(@draft) end)

      assert Adoption.probe_resource(@draft) == :not_adopted

      log =
        capture_log(fn ->
          assert {:ok, []} = Server.list_drafts_result(ai_mount(), org_id)
          assert {:ok, []} = Server.list_drafts_result(ai_mount(), org_id)
        end)

      assert length(String.split(log, "feature not adopted on this host")) - 1 == 1
      refute log =~ "read failed"

      {_socket, html} = with_log(fn -> compose(org_id) end) |> elem(0)
      assert html =~ "has not adopted the AI draft domain"
      refute html =~ "Try again"
    end

    test "REAL failure on an ADOPTING host (repo configured, not running): the list is an error, compose says try again, never 'not adopted'",
         %{org_id: org_id} do
      configure_repo!(SamenCore.TestRepo)
      assert Adoption.probe_resource(@draft) == :repo_down

      {result, log} = with_log(fn -> Server.list_drafts_result(ai_mount(), org_id) end)
      assert result == {:error, :unavailable}
      assert log =~ "read failed read=ai_list_drafts"

      {{socket, html}, _log} = with_log(fn -> compose(org_id) end)
      assert socket.assigns.drafts_error
      assert html =~ "Draft could not be saved — nothing was saved. Try again."
      refute html =~ "has not adopted"
      refute html =~ "No drafts yet"
    end

    test "a denial outcome renders denial copy, distinct from the outage and not-adopted copy", %{org_id: org_id} do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(samen_mount: ai_mount(), samen_acting_as: false)
        |> then(&SupportDraftLive.load(&1, org_id, outcome: {:denied, "You are not allowed to compose a support draft here — nothing was saved."}))

      html = render_html(SupportDraftLive, socket.assigns)
      assert html =~ ~s(data-state="denied")
      assert html =~ "not allowed"
      refute html =~ "Try again"
      refute html =~ "has not adopted"
    end

    test "Adoption.probe decides from facts: ready / missing table / down repo / never configured" do
      repo = Samen.WebTest.Repo
      table = AshPostgres.DataLayer.Info.table(Samen.WebTest.Operator.Invitation)

      # POSITIVE CONTROL: a started repo with the table is ready.
      assert Adoption.probe(repo, table) == :ready

      break_table!(Samen.WebTest.Operator.Invitation)
      assert Adoption.probe(repo, table) == :table_missing

      assert Adoption.probe(SamenCore.TestRepo, "anything") == :not_adopted
      configure_repo!(SamenCore.TestRepo)
      assert Adoption.probe(SamenCore.TestRepo, "anything") == :repo_down
      assert Adoption.probe(nil, "anything") == :not_adopted
    end
  end

  # ===========================================================================
  # N4 — impersonation sessions: the genuinely-absent table is the honest empty
  # ===========================================================================

  describe "N4 — security settings, impersonation sessions" do
    alias Samen.Web.Settings.SecurityLive
    alias Samen.WebTest.Operator.{Membership, User}

    defp security_render(org_id, user_id) do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(samen_mount: build_mount(:settings), samen_acting_as: false, return_to: nil)
        |> then(&SecurityLive.load(&1, org_id, user_id))

      render_html(SecurityLive, socket.assigns)
    end

    setup do
      org_id = Ash.UUID.generate()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "sec-admin", full_name: %Samen.Type.FullName{first: "Sec", last: "Admin"}})
        |> Ash.create!(authorize?: false)

      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin})
      |> Ash.create!(authorize?: false)

      %{sec_org: org_id, sec_user: user.id}
    end

    test "a host WITHOUT the sessions table shows the documented honest empty; a present table with a broken query is still an error",
         %{sec_org: org_id, sec_user: user_id} do
      # POSITIVE CONTROL: the table is there and empty → "No impersonation sessions recorded."
      healthy = security_render(org_id, user_id)
      assert healthy =~ "No impersonation sessions recorded."
      refute healthy =~ "security-sessions-unavailable"

      table = Samen.Impersonation.Session.__schema__(:source)

      # A REAL outage-shaped failure on a PRESENT table (the column the read selects is gone).
      Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME COLUMN imp_org_id TO zz_org_id")
      {broken, _log} = with_log(fn -> security_render(org_id, user_id) end)
      assert broken =~ "security-sessions-unavailable"
      refute broken =~ "No impersonation sessions recorded."
      Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME COLUMN zz_org_id TO imp_org_id")

      # The genuinely-absent table: structural check → honest empty, no error state.
      Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "ALTER TABLE #{table} RENAME TO zz_gone_#{table}")
      absent = security_render(org_id, user_id)
      assert absent =~ "No impersonation sessions recorded."
      refute absent =~ "security-sessions-unavailable"
    end
  end
end
