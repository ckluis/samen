defmodule Samen.Web.TenantRoleIcsTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), the `.ics` export: the controller acts with the role the signed-in person's
  ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Mount.scope/2`'s fixed `:member`.

  Role choice: the export is the person's own organisation's calendar, read-only, so every active member (a viewer included)
  downloads it; nobody without an active membership does (403), and a failed membership lookup is a 503, never a file.
  The role the export ran as is pinned through the `:samen_acting_role` assign the controller sets, as the CSV export's is.

  The controller is called with the mount set by hand and a REAL login session (`Samen.WebTest.RoleHarness`).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Web.Ics.ExportController
  alias Samen.Web.Mount
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SpineAccounts

  @labels %{
    otp_app: :samen_web_security_test_host,
    title: "Security Probe",
    authn: {:app_env, :samen_web_security_test_host, :auth_required?},
    authorized_orgs: {Samen.WebTest.SecurityHost, :authorized_org_ids, []},
    identity_namespace: Samen.WebTest.Operator
  }

  setup do
    ctx = H.setup_accounts()

    Samen.WebTest.Calendar.Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: ctx.org_id,
        title: "Board Sync Zebra",
        starts_at: ~U[2026-04-01 15:00:00.000000Z],
        ends_at: ~U[2026-04-01 16:00:00.000000Z],
        location: "HQ",
        attendees: []
      },
      authorize?: false
    )
    |> Ash.create!()

    ctx
  end

  defp mount(labels \\ @labels), do: Mount.new(:calendar, Samen.WebTest.Calendar, Samen.WebTest.Repo, labels: labels)

  defp export(login, mount, org_id) do
    build_conn(:get, "/calendar.ics?org=#{org_id}")
    |> Plug.Test.init_test_session(login.session)
    |> Map.put(:assigns, %{samen_mount: mount})
    |> ExportController.export(%{"org" => org_id})
  end

  test "the export acts as the RESOLVED role (a viewer is a viewer, not a member) and serves the calendar", ctx do
    for who <- [:viewer, :member, :admin, :owner] do
      conn = export(H.log_in(Map.fetch!(ctx, who)), mount(), ctx.org_id)
      assert conn.status == 200, "#{who}"
      assert conn.assigns[:samen_acting_role] == who
      assert conn.resp_body =~ "Board Sync Zebra"
    end
  end

  # A LEGACY-session principal the host's `:authorized_orgs` seam grants the org: the org resolves, so it is the membership
  # lookup alone that decides the role (a suspended spine member would simply fall back to its own org and never get here).
  defp legacy_login(account, org_id) do
    {:ok, %{user_id: user_id}} =
      Samen.Auth.OrgActor.resolve(%{user: Samen.WebTest.Operator.User, membership: Samen.WebTest.Operator.Membership}, account.credential.id, org_id)

    Samen.WebTest.SecurityHost.grant!(user_id, [org_id])
    on_exit(&Samen.WebTest.SecurityHost.revoke_all!/0)
    %{session: %{"samen_current_user" => user_id}}
  end

  test "no active membership is a 403 and nothing is exported; a failed lookup is a 503", ctx do
    # positive control: the same legacy session while the membership is active
    assert export(legacy_login(ctx.member, ctx.org_id), mount(), ctx.org_id).status == 200

    login = legacy_login(ctx.member, ctx.org_id)
    SpineAccounts.suspend!(ctx.member, ctx.org_id)
    denied = export(login, mount(), ctx.org_id)
    assert denied.status == 403
    refute denied.resp_body =~ "Zebra"

    broken = mount(Map.put(@labels, :identity_namespace, Samen.WebTest.NoSuchIdentity))

    {unavailable, _log} = ExUnit.CaptureLog.with_log(fn -> export(legacy_login(ctx.viewer, ctx.org_id), broken, ctx.org_id) end)
    assert unavailable.status == 503
    refute unavailable.resp_body =~ "Zebra"
  end
end
