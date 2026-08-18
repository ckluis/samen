defmodule Samen.Web.CurrentOrgTest do
  @moduledoc """
  Framework CURRENT-ORG resolution tests (ADR-013 §4). Proves the single resolution order
  (param → session → mount default label → first-listable → nil), the tenant directory + name
  resolution, the switcher listing + session-write links, and the seed-state (never dead-end)
  empty rule. Pure/unit where possible; DB-backed for the directory over the operator accounts.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  # A directory MFA the test host wires — mirrors what Driftwood's `Driftwood.Directory.orgs/0`
  # does: a static `[{org_id, name}]` list. Public so the mount MFA can call it.
  def dir_fixture do
    [
      {"11111111-0000-4000-8000-000000000001", "Summit Freight Partners"},
      {"11111111-0000-4000-8000-000000000002", "Blue Ridge Logistics"}
    ]
  end

  defp crm_mount(labels) do
    Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant(), labels: labels)
  end

  # ==========================================================================
  # resolve/3 — the ONE resolution order (first hit wins)
  # ==========================================================================

  test "resolve/3: param wins over session, default, and directory" do
    mount = crm_mount(%{default_org_id: "DEFAULT", org_directory: {__MODULE__, :dir_fixture, []}})
    params = %{"org" => "FROM-PARAM"}
    session = %{"samen_current_org" => "FROM-SESSION"}

    assert CurrentOrg.resolve(mount, params, session) == "FROM-PARAM"
  end

  test "resolve/3: session wins over default + directory when no param" do
    mount = crm_mount(%{default_org_id: "DEFAULT", org_directory: {__MODULE__, :dir_fixture, []}})
    assert CurrentOrg.resolve(mount, %{}, %{"samen_current_org" => "FROM-SESSION"}) == "FROM-SESSION"
  end

  test "resolve/3: the mount default label wins over the directory when no param/session" do
    mount = crm_mount(%{default_org_id: "DEFAULT", org_directory: {__MODULE__, :dir_fixture, []}})
    assert CurrentOrg.resolve(mount, %{}, %{}) == "DEFAULT"
  end

  test "resolve/3: first-listable org when only the directory is set (no default)" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})
    # Directory is sorted by name → "Blue Ridge Logistics" is first.
    assert CurrentOrg.resolve(mount, %{}, %{}) == "11111111-0000-4000-8000-000000000002"
  end

  test "resolve/3: nil ONLY when nothing resolves (no dead-end mechanism, a nil is a seed-state)" do
    mount = crm_mount(nil)
    assert CurrentOrg.resolve(mount, %{}, %{}) == nil
  end

  test "resolve/3: a blank param/session is treated as absent" do
    mount = crm_mount(%{default_org_id: "DEFAULT"})
    assert CurrentOrg.resolve(mount, %{"org" => ""}, %{"samen_current_org" => "  "}) == "DEFAULT"
  end

  # ==========================================================================
  # list_orgs/1 + name/2 — the directory (powers the switcher + the header name)
  # ==========================================================================

  test "list_orgs/1: reads the mount's :org_directory MFA, sorted by name" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})

    assert CurrentOrg.list_orgs(mount) == [
             {"11111111-0000-4000-8000-000000000002", "Blue Ridge Logistics"},
             {"11111111-0000-4000-8000-000000000001", "Summit Freight Partners"}
           ]
  end

  test "list_orgs/1: empty when no directory seam is wired (switcher then hides)" do
    assert CurrentOrg.list_orgs(crm_mount(nil)) == []
  end

  test "name/2: resolves the org's display name from the directory (fixes the 'Workspace' bug)" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}, title: "FallbackTitle"})
    assert CurrentOrg.name(mount, "11111111-0000-4000-8000-000000000001") == "Summit Freight Partners"
  end

  test "name/2: falls back to the mount :title, then 'Workspace', when the org is not listable" do
    mount = crm_mount(%{title: "FallbackTitle"})
    assert CurrentOrg.name(mount, "unknown-id") == "FallbackTitle"
    assert CurrentOrg.name(crm_mount(nil), "unknown-id") == "Workspace"
    assert CurrentOrg.name(crm_mount(nil), nil) == "Workspace"
  end

  # ==========================================================================
  # no_org?/2 — the seed-state rule (never the type-a-UUID dead-end)
  # ==========================================================================

  test "no_org?/2: false whenever an org resolved" do
    refute CurrentOrg.no_org?(crm_mount(nil), "any-org")
  end

  test "no_org?/2: true only when no org AND the directory is empty (unseeded)" do
    assert CurrentOrg.no_org?(crm_mount(nil), nil)
    refute CurrentOrg.no_org?(crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}}), nil)
  end

  # ==========================================================================
  # acting_as?/1 — the true "explicit act-as" signal (gates the banner)
  # ==========================================================================

  test "acting_as?/1: true only when the session carries an explicit samen_current_org" do
    assert CurrentOrg.acting_as?(%{"samen_current_org" => "FROM-SESSION"})
    # A plain tenant default-org visit (no session org) is NOT an act-as.
    refute CurrentOrg.acting_as?(%{})
    refute CurrentOrg.acting_as?(%{"samen_current_org" => "  "})
    refute CurrentOrg.acting_as?(nil)
  end

  # ==========================================================================
  # plane_badge/1 (== acting_as_banner/1) — the T116 persistent plane-legibility
  # badge: a tenant/operator plane label on EVERY surface + the acting-as crossing
  # marker. `acting_as_banner/1` delegates to `plane_badge/1` (backwards-compatible
  # entry the ≈44 LiveViews already call), so both render the identical DOM.
  # ==========================================================================

  test "plane_badge/1: a tenant-plane mount renders a TENANT badge with the resolved org name" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})
    org_id = "11111111-0000-4000-8000-000000000001"
    html = render_badge(%{mount: mount, org_id: org_id, acting_as: false})

    # The previously-UNLABELLED tenant plane now carries an explicit, machine-readable label.
    assert html =~ ~s(data-plane="tenant")
    assert html =~ "Tenant plane"
    assert html =~ "Summit Freight Partners"
    # NOT the crossing marker on a plain visit.
    refute html =~ "acting-as-bar"
    refute html =~ ~s(data-crossing="true")
  end

  test "plane_badge/1: an OPERATOR-scope mount renders an OPERATOR badge (its own workspace name)" do
    op_mount =
      Mount.new(:operator, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{operator_workspace: "Driftwood Ops"}
      )

    html = render_badge(%{mount: op_mount, org_id: "any", acting_as: false})

    assert html =~ ~s(data-plane="operator")
    assert html =~ "Operator plane"
    assert html =~ "Driftwood Ops"
  end

  # ---- the crossing marker: the operator→tenant act-as must be VISIBLY marked ----
  # (sabotage-refutable in spirit: if the `:if={@crossing?}` marker branch were removed,
  #  the `acting-as-bar` element + "acting as tenant" text vanish and this test fails.)

  test "plane_badge/1: operator ACTING AS a tenant renders the VISIBLE crossing marker" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}, operator_workspace: "Driftwood Ops"})
    org_id = "11111111-0000-4000-8000-000000000001"
    html = render_badge(%{mount: mount, org_id: org_id, acting_as: true})

    # The crossing element + its unmistakable copy — the human-facing counterpart to the
    # T115/T38 impersonation-write audit. Removing the marker fails HERE.
    assert html =~ "acting-as-bar"
    assert html =~ ~s(data-crossing="true")
    assert html =~ "acting as tenant"
    assert html =~ "Summit Freight Partners"
    # A way back UP to the operator plane, labelled by the host (not hardcoded).
    assert html =~ "Return to Driftwood Ops"
    # The empty-name bug guard.
    refute html =~ "<b></b>"
  end

  test "plane_badge/1: the acting-as crossing marker never fires on the operator plane itself" do
    operator_plane = Samen.Web.Plane.operator("op-1", "11111111-0000-4000-8000-000000000001")
    operator_mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: operator_plane)
    html = render_badge(%{mount: operator_mount, org_id: "any", acting_as: true})

    refute html =~ "acting-as-bar"
    # It still self-labels as the operator plane.
    assert html =~ ~s(data-plane="operator")
  end

  # ---- attempt-2 defense-in-depth: the crossing is derived from ACTOR CONTEXT, not solely
  # the sticky `samen_current_org` breadcrumb. An operator actor on a tenant surface is a
  # crossing even when acting_as is FALSE — so a future mislink can't recreate a SILENT
  # crossing (the byte-identical plain-tenant badge the verifier reproduced). Sabotage-
  # refutable: drop the `operator_actor` term from crossing?/2 and this test fails. ----

  test "plane_badge/1: an OPERATOR ACTOR on a tenant surface is marked even with acting_as=false" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}, operator_workspace: "Driftwood Ops"})
    org_id = "11111111-0000-4000-8000-000000000001"

    silent = render_badge(%{mount: mount, org_id: org_id, acting_as: false})
    marked = render_badge(%{mount: mount, org_id: org_id, acting_as: false, operator_actor: true})

    # WITHOUT the operator-actor signal a plain tenant badge (the pre-fix silent state)…
    refute silent =~ "acting-as-bar"
    # …WITH it, the crossing marker fires from actor context alone — no acting-as session key.
    assert marked =~ "acting-as-bar"
    assert marked =~ ~s(data-crossing="true")
    assert marked =~ "acting as tenant"
    # The two DOMs are NOT byte-identical — the A==B silent-crossing state cannot recur.
    refute silent == marked
  end

  defp render_badge(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> CurrentOrg.acting_as_banner()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ==========================================================================
  # return_path/1 — the switcher's same-module return target
  # ==========================================================================

  test "return_path/1: strips the query, keeps the absolute path; nil for junk" do
    assert CurrentOrg.return_path("http://localhost:4000/crm/contacts?org=x") == "/crm/contacts"
    assert CurrentOrg.return_path("/billing/invoices") == "/billing/invoices"
    assert CurrentOrg.return_path(nil) == nil
    assert CurrentOrg.return_path("") == nil
  end

  # ==========================================================================
  # switcher/1 — lists the orgs + writes the session via the SessionController
  # ==========================================================================

  test "switcher/1: renders a link per org to the session-write endpoint + the host's operator entry" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}, operator_workspace: "Driftwood Ops"})
    html = render_switcher(%{mount: mount, org_id: "11111111-0000-4000-8000-000000000001", return_to: "/crm/contacts"})

    # A row per org, each targeting the framework SessionController with return_to preserved.
    assert html =~ "workspace-switcher"
    assert html =~ "/session/org/11111111-0000-4000-8000-000000000001?return_to=%2Fcrm%2Fcontacts"
    assert html =~ "/session/org/11111111-0000-4000-8000-000000000002?return_to=%2Fcrm%2Fcontacts"
    assert html =~ "Summit Freight Partners"
    # The pinned "return to operator plane" entry — labelled from the MOUNT, not hardcoded.
    assert html =~ "/operator/accounts"
    assert html =~ "Driftwood Ops"
  end

  # ==========================================================================
  # P9-F2 DE-HARDCODE — the framework-first proof: the SHARED chrome no longer
  # emits "Driftwood Ops"/"mix driftwood.seed"; a non-driftwood host renders ITS
  # OWN boundary label through the SAME components with only different mount data.
  # ==========================================================================

  # A pawchart-shaped mount: its own title, NO operator_workspace/seed_command wired
  # (pawchart is mono-plane — it should never inherit driftwood's brand).
  defp pawchart_mount do
    crm_mount(%{title: "Happy Paws Clinic"})
  end

  test "switcher/1: a non-driftwood host's operator entry is NEUTRAL, never 'Driftwood Ops'" do
    html =
      render_switcher(%{
        mount: crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}}),
        org_id: nil,
        return_to: nil
      })

    refute html =~ "Driftwood Ops"
    # The neutral framework default labels the boundary honestly.
    assert html =~ "Operator (operator)"
  end

  test "no_org_card/1: driftwood's mount renders ITS seed command + operator label" do
    mount = crm_mount(%{seed_command: "mix driftwood.seed", operator_workspace: "Driftwood Ops"})
    html = render_no_org(%{mount: mount})

    assert html =~ "mix driftwood.seed"
    assert html =~ "Back to Driftwood Ops"
  end

  test "no_org_card/1: a non-driftwood host renders NEITHER 'mix driftwood.seed' NOR 'Driftwood Ops'" do
    html = render_no_org(%{mount: pawchart_mount()})

    # The framework leak is gone — pawchart's empty state names no foreign vertical.
    refute html =~ "Driftwood"
    refute html =~ "mix driftwood.seed"
    # Vertical-neutral copy + the neutral operator label instead.
    assert html =~ "Seed the demo to populate the workspaces"
    assert html =~ "Back to Operator"
  end

  test "plane_badge/1: a pawchart-shaped host renders ITS OWN org name, not Driftwood's" do
    html = render_badge(%{mount: pawchart_mount(), org_id: "unknown-id", acting_as: false})

    assert html =~ "Happy Paws Clinic"
    assert html =~ ~s(data-plane="tenant")
    refute html =~ "Driftwood"
  end

  defp render_no_org(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> CurrentOrg.no_org_card()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_switcher(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> CurrentOrg.switcher()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "switcher/1: hides entirely when the directory is empty" do
    html = render_switcher(%{mount: crm_mount(nil), org_id: nil, return_to: nil})
    refute html =~ "workspace-switcher"
  end

  # ==========================================================================
  # The DB-backed directory over the operator accounts (operator/aggregate mounts)
  # ==========================================================================

  test "list_orgs/1: an operator mount reads its accounts directly (each account IS a tenant org)" do
    seed = OpSeeds.seed_all(tenants: 2)
    mount = build_operator_mount(seed.operator_org_id)

    orgs = CurrentOrg.list_orgs(mount)
    ids = Enum.map(orgs, &elem(&1, 0))

    assert length(orgs) == 2
    assert seed.tenant_org_id in ids
    # Names are the account org names (non-PII) — clear, listable in the switcher.
    assert Enum.any?(orgs, fn {_id, name} -> name =~ "Blue Ridge Logistics" end)
  end
end
