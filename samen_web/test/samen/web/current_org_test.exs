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
  # acting_as_banner/1 — shows the RESOLVED org name, ONLY during a real act-as
  # ==========================================================================

  test "acting_as_banner/1: renders the resolved org NAME (never an empty <b>) during an act-as" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})
    org_id = "11111111-0000-4000-8000-000000000001"
    html = render_banner(%{mount: mount, org_id: org_id, acting_as: true})

    assert html =~ "acting-as-bar"
    assert html =~ "Summit Freight Partners"
    # The empty-name bug: the <b> must NOT be empty.
    refute html =~ "<b></b>"
  end

  test "acting_as_banner/1: hidden on a plain default-org visit (acting_as false)" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})
    org_id = "11111111-0000-4000-8000-000000000001"
    html = render_banner(%{mount: mount, org_id: org_id, acting_as: false})

    refute html =~ "acting-as-bar"
  end

  test "acting_as_banner/1: hidden on the operator plane even when acting_as is true" do
    operator_plane = Samen.Web.Plane.operator("op-1", "11111111-0000-4000-8000-000000000001")
    operator_mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: operator_plane)
    html = render_banner(%{mount: operator_mount, org_id: "any", acting_as: true})

    refute html =~ "acting-as-bar"
  end

  defp render_banner(assigns) do
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

  test "switcher/1: renders a link per org to the session-write endpoint + a Driftwood Ops entry" do
    mount = crm_mount(%{org_directory: {__MODULE__, :dir_fixture, []}})
    html = render_switcher(%{mount: mount, org_id: "11111111-0000-4000-8000-000000000001", return_to: "/crm/contacts"})

    # A row per org, each targeting the framework SessionController with return_to preserved.
    assert html =~ "workspace-switcher"
    assert html =~ "/session/org/11111111-0000-4000-8000-000000000001?return_to=%2Fcrm%2Fcontacts"
    assert html =~ "/session/org/11111111-0000-4000-8000-000000000002?return_to=%2Fcrm%2Fcontacts"
    assert html =~ "Summit Freight Partners"
    # The pinned "return to operator plane" entry.
    assert html =~ "/operator/accounts"
    assert html =~ "Driftwood Ops"
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
