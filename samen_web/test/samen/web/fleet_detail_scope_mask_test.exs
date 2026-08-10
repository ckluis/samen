defmodule Samen.Web.FleetDetailScopeMaskTest do
  @moduledoc """
  RP-J-14 (ADR-044 §16.2/§16.3/§16.4a, T84b) — the scope-mask 3-proof for
  `Samen.Web.Operator.FleetDetailLive`'s tier-2 name resolution, consuming
  T84a's `Samen.ScopeMaskCase` harness (the SECOND mask class — mask by
  omission, no `••••`, no plane).

    * **green** — a viewer whose `scope_of/2` covers the handle sees the
      display name inline (`assert_scope_resolved!/2`).
    * **red** — a viewer with `roles[app_id]` but an `{:accounts, …}` scope
      EXCLUDING the handle sees a masked row: no name, no `org_id`, no deep
      link, and no handle ANYWHERE in the DOM (`assert_scope_masked!/3`).
    * **sabotage twin** — flip `scope_of/2` permissive and the red assertion
      must FAIL (`assert_leak_detected!/2`).
    * **mixed-render** (the salesperson case) — ONE table, ONE viewer: named
      rows for in-scope accounts, masked rows for out-of-scope accounts, in a
      SINGLE render.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.ScopeMaskCase

  alias Samen.Fleet.{AdminActor, Handle, Registry, Resolution}
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FleetDetailLive

  @ns Samen.WebTest.Fleet
  @otp_app :samen_web_fleet_detail_scope_test_host
  @admin AdminActor.new("seed-admin")

  # Literal atoms so String.to_existing_atom/1 (Samen.Web.Operator.Fleet.app_scope/1)
  # resolves them — a product slug is a small, fleet-admin-known set in practice
  # (§6.2's own example wires :driftwood/:pawchart literally), so referencing the
  # atom here mirrors how a real host's own compiled config mints it.
  @slug_full :smx1

  setup do
    Application.put_env(@otp_app, :fleet, mode: :manual)

    on_exit(fn ->
      Application.delete_env(@otp_app, :fleet)
      Application.delete_env(@otp_app, :fleet_name_resolver)
      Application.delete_env(@otp_app, :fleet_resolution)
      Application.delete_env(@otp_app, :fleet_authority)
    end)

    alpha_org = Ecto.UUID.generate()
    beta_org = Ecto.UUID.generate()

    {:ok, %{app: app}} =
      Registry.register_app(@ns, %{slug: Atom.to_string(@slug_full), display_name: "Full Product"}, @admin)

    {:ok, alpha_handle} = Handle.compute(app.id, alpha_org, [])
    {:ok, beta_handle} = Handle.compute(app.id, beta_org, [])

    payload =
      Samen.Fleet.Report.build(app_id: app.id)
      |> Samen.Fleet.Report.to_wire()
      |> Map.put("deliverability", [
        %{"handle" => alpha_handle, "sent" => 100, "bounced" => 2, "complained" => 0, "health_index" => 95},
        %{"handle" => beta_handle, "sent" => 50, "bounced" => 1, "complained" => 0, "health_index" => 90}
      ])

    {:ok, _} = Registry.record_report(@ns, app.id, payload, :pull)

    %{app: app, alpha_org: alpha_org, beta_org: beta_org, alpha_handle: alpha_handle, beta_handle: beta_handle}
  end

  def const(value, _principal_id), do: value

  defp render_for(fixture, roles, scope) do
    Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :const, [roles]})
    Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :const, [scope]})

    Application.put_env(@otp_app, :fleet_name_resolver,
      {Resolution, :resolve_via_org_scan,
       [
         @otp_app,
         fn -> [%{id: fixture.alpha_org, name: "Alpha Co"}, %{id: fixture.beta_org, name: "Beta Co"}] end,
         fixture.app.id
       ]}
    )

    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
      )

    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)
    {:ok, socket} = FleetDetailLive.mount(%{"app_id" => fixture.app.id}, %{}, socket)
    render_html(FleetDetailLive, socket.assigns)
  end

  describe "RP-J-14 — the scope-mask 3-proof" do
    test "GREEN: an :all-scope viewer sees both tenant names inline", fixture do
      html = render_for(fixture, %{fleet: :operator_admin, smx1: :operator_admin}, :all)

      assert_scope_resolved!(html, ["Alpha Co", "Beta Co"])
    end

    test "RED: a :none-scope viewer (fleet+app role, no account scope) sees NEITHER name nor handle", fixture do
      html = render_for(fixture, %{fleet: :operator_readonly, smx1: :operator_readonly}, :none)

      assert_scope_masked!(html, ["Alpha Co", "Beta Co"], [fixture.alpha_handle, fixture.beta_handle])
    end

    test "RED: a scoped-out {:accounts, other_org} viewer sees neither for the excluded handles", fixture do
      html =
        render_for(
          fixture,
          %{fleet: :operator_readonly, smx1: :operator_readonly},
          {:accounts, MapSet.new(["some-other-org-entirely"])}
        )

      assert_scope_masked!(html, ["Alpha Co", "Beta Co"], [fixture.alpha_handle, fixture.beta_handle])
    end

    test "SABOTAGE TWIN: flipping scope_of/2 permissive leaks the name+handle — the red assertion FAILS", fixture do
      # The genuine red proof, first (proves the mask holds under the real seam).
      masked_html = render_for(fixture, %{fleet: :operator_readonly, smx1: :operator_readonly}, :none)
      assert_scope_masked!(masked_html, ["Alpha Co"], [fixture.alpha_handle])

      # The sabotage: scope_of/2 permissive (:all) for the SAME viewer — the mask
      # discipline is refutable: the leak actually shows up, so the assertion above
      # is not vacuously true.
      permissive_html = render_for(fixture, %{fleet: :operator_readonly, smx1: :operator_readonly}, :all)
      assert_leak_detected!(permissive_html, "Alpha Co")

      # And the RED assertion genuinely FAILS against the permissive render (proven
      # via ExUnit.Assertions.assert/2's own failure, captured rather than raised).
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(permissive_html, ["Alpha Co"], [fixture.alpha_handle])
      end
    end
  end

  describe "mixed-render — one table, one viewer, named + masked rows (§16.3 salesperson case)" do
    test "a sales-rep scoped to ONE account sees it named and the OTHER masked, in the SAME render", fixture do
      html =
        render_for(
          fixture,
          %{fleet: :operator_readonly, smx1: :operator_readonly},
          {:accounts, MapSet.new([fixture.beta_org])}
        )

      assert_scope_resolved!(html, ["Beta Co"])
      assert_scope_masked!(html, ["Alpha Co"], [fixture.alpha_handle])
    end
  end

  describe "k-anon floor survives the cockpit render (RP-J-7 consumption)" do
    test "a %Suppressed{}-shaped cohort cell renders '⊘', never the underlying wire value", fixture do
      alpha_handle = fixture.alpha_handle

      payload =
        Samen.Fleet.Report.build(app_id: fixture.app.id)
        |> Samen.Fleet.Report.to_wire()
        |> Map.put("deliverability", [
          %{
            "handle" => alpha_handle,
            "sent" => 3,
            "bounced" => %{"suppressed" => true, "reason" => "k_anonymity", "k" => 3, "l" => nil, "observed" => nil, "limit" => 5},
            "complained" => 0,
            "health_index" => 90
          }
        ])

      {:ok, _} = Registry.record_report(@ns, fixture.app.id, payload, :pull)

      html = render_for(fixture, %{fleet: :operator_admin, smx1: :operator_admin}, :all)

      assert html =~ "⊘"
      # the wire-carried k-anon floor detail must NOT reach the rendered cell.
      refute html =~ "k_anonymity"
    end
  end

  # P16 (phase6-punchlist / ADR-044 §16.2) — a separately-deployed cockpit whose
  # deployment never received the `:fleet_name_resolver` seam masks EVERY cohort name.
  # That is a whole-page "resolution seam not reachable" condition — NOT the per-row
  # "not in your scope" authz outcome. It already fails closed by construction (resolve/3
  # returns %{} for every handle); this pins the ATTRIBUTION and proves no leak.
  defp render_without_name_seam(fixture, roles) do
    Application.put_env(@otp_app, :fleet_authority, {__MODULE__, :const, [roles]})
    # A permissive SCOPE seam is wired (so the mask is NOT a scope outcome) but the
    # NAME-resolution seam is deliberately absent — the separately-deployed split.
    Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :const, [:all]})
    Application.delete_env(@otp_app, :fleet_name_resolver)

    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{otp_app: @otp_app, fleet_namespace: @ns, fleet_cockpit: true}
      )

    socket = %Phoenix.LiveView.Socket{} |> Phoenix.Component.assign(:samen_mount, mount)
    {:ok, socket} = FleetDetailLive.mount(%{"app_id" => fixture.app.id}, %{}, socket)
    render_html(FleetDetailLive, socket.assigns)
  end

  describe "P16 — separately-deployed / seam-not-reachable attribution (§16.2)" do
    test "an in-product-scope operator with NO name-resolution seam sees the whole-page 'seam not reachable' copy, never per-row 'not in your scope'",
         fixture do
      html = render_without_name_seam(fixture, %{fleet: :operator_admin, smx1: :operator_admin})

      # Whole-page attribution (the ADR §16.2 copy), and its cause named honestly.
      assert html =~ "resolution seam not reachable"

      # NOT misattributed to per-viewer scope — the old per-row copy must be absent.
      refute html =~ "not in your scope"

      # Fail-closed either way: no resolved tenant name and no raw handle leaks into the DOM.
      refute html =~ "Alpha Co"
      refute html =~ "Beta Co"
      refute html =~ fixture.alpha_handle
      refute html =~ fixture.beta_handle
    end

    test "ANTI-TAUTOLOGY: with the name seam WIRED, an out-of-scope handle is attributed to scope ('not in your scope'), not the seam",
         fixture do
      # Same viewer, but the name seam IS reachable and scope EXCLUDES the handles: the
      # honest cause flips back to per-row scope — proving the P16 test above is real.
      html =
        render_for(
          fixture,
          %{fleet: :operator_readonly, smx1: :operator_readonly},
          {:accounts, MapSet.new(["some-other-org-entirely"])}
        )

      assert html =~ "not in your scope"
      refute html =~ "resolution seam not reachable"
    end
  end

  describe "§5.4 tier-2 app-level gate (independent of name scope)" do
    test "no roles[app_id] -> the whole cohort's COUNTS are hidden, regardless of name scope", fixture do
      # roles[:fleet] present but NO entry for THIS app's slug (:smx1 absent) — the
      # container page still renders (roles[:fleet] holds) but this row's counts (and
      # therefore its names) are gated OUT independent of the name-resolution seam.
      html = render_for(fixture, %{fleet: :operator_readonly}, :all)

      assert html =~ "not in your product scope" or html =~ "Not in your product scope"
      refute html =~ "Alpha Co"
      refute html =~ "Beta Co"
    end
  end
end
