defmodule Samen.Web.BillingPlansCrudTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — `Samen.Web.Billing.PlansLive` on the A2 kit
  contract (`ListLive` + `list_view` + `simple_form`/`modal`/`delete_confirm`). Plans
  are non-PII Tier-0 config rows; the kernel gates writes with `RoleAtLeast :admin`
  (the tenant write path goes through `Reads.write_scope/2`, a same-org PLANE-PRESERVING
  role elevation):

    * **CRUD (AC-G1-1/2)** — "New plan" is a REAL button opening the modal +
      `simple_form`; an INVALID submit renders inline errors and persists NOTHING; a
      VALID submit persists + refreshes the bounded list; the enable/disable toggle is
      the sanctioned "plan change" update; each row carries `delete_confirm/1` with a
      FAIL-HONEST FK refusal.
    * **Bounded read (AC-G1-5)** — `plans_page/3` passes `Samen.Web.Reads.bounded!/4`
      non-vacuously (dataset > probe page size) and keyset pagination walks the set.
    * **Operator posture (belt)** — no write affordance in the operator DOM. (The
      write-path suspenders for the billing PII surface live in
      `billing_overview_crud_test.exs` — plans carry no PII.)
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.PlansLive
  alias Samen.Web.Billing.Reads
  alias Samen.Web.ListLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> PlansLive.load(org_id)
  end

  defp html(socket), do: render_html(PlansLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = PlansLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp plan_count(org_id) do
    Samen.WebTest.Billing.Plan
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp seed_plans(org_id, n) do
    for i <- 1..n do
      Samen.WebTest.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "plan-#{String.pad_leading(to_string(i), 2, "0")}", interval: :monthly},
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  # ---------------------------------------------------------------------------
  # Create — green + red (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New plan opens the modal; a VALID submit persists and refreshes the bounded list" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-plan")
    assert rendered =~ ~s(phx-click="new_plan")

    socket = event(socket, "new_plan", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-plan-form")
    assert rendered =~ ~s(name="form[name]")

    socket =
      event(socket, "save_new", %{
        "form" => %{"name" => "custom", "label" => "Custom", "description" => "Bespoke tier", "interval" => "monthly"}
      })

    refute socket.assigns.show_new
    assert plan_count(org_id) == 1
    assert html(socket) =~ "Custom"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (missing required name) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_plan", %{})

    socket = event(socket, "save_new", %{"form" => %{"label" => "No Name", "interval" => "monthly"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert plan_count(org_id) == 0
    assert socket.assigns.page.items == []
  end

  # ---------------------------------------------------------------------------
  # The sanctioned "plan change" — enable/disable toggle (update: :*)
  # ---------------------------------------------------------------------------

  test "toggle_plan flips enabled through the sanctioned update action and refreshes" do
    org_id = Ash.UUID.generate()
    [plan] = seed_plans(org_id, 1)
    assert plan.enabled

    socket = mount_socket(org_id)
    assert html(socket) =~ ~s(phx-click="toggle_plan")

    socket = event(socket, "toggle_plan", %{"id" => plan.id})
    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    refute raw.enabled
    assert html(socket) =~ "disabled"

    _socket = event(socket, "toggle_plan", %{"id" => plan.id})
    raw = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
    assert raw.enabled
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + FAIL-HONEST FK refusal
  # ---------------------------------------------------------------------------

  test "delete destroys a bare plan; a plan with linked prices is REFUSED and the refusal is surfaced" do
    %{org_id: org_id, billing: %{plan: linked_plan}} = Seeds.seed_all()
    [bare_plan] = seed_plans(org_id, 1)

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{bare_plan.id}")

    socket = event(socket, "delete", %{"id" => bare_plan.id})
    assert plan_count(org_id) == 1
    refute html(socket) =~ "plan-#{bare_plan.name}"

    # FAIL-HONEST: the seeded plan carries a price (FK) — refused, surfaced, unchanged.
    socket = event(socket, "delete", %{"id" => linked_plan.id})
    assert plan_count(org_id) == 1
    assert html(socket) =~ "Could not delete this plan"
  end

  # ---------------------------------------------------------------------------
  # Bounded read + pagination (AC-G1-5 / RP-G1-5 per-surface)
  # ---------------------------------------------------------------------------

  test "plans_page/3 is BOUNDED (bounded!/4 passes non-vacuously) and keyset pagination walks the set" do
    org_id = Ash.UUID.generate()
    seed_plans(org_id, 12)
    mount = build_mount(:billing)
    scope = Mount.scope(mount, org_id)

    # The lint exercises the read against 12 rows with a probe page of 10 — an
    # unbounded read would RAISE here (the central RP-G1-5 red path proves the raise).
    assert :ok == WebReads.bounded!(&Reads.plans_page/3, mount, scope, page_size: 10)

    socket = mount_socket(org_id)
    assert length(socket.assigns.page.items) == 12

    # Walk with an explicit small page via the list state (paginate next/prev).
    socket = list_event(socket, "filter", %{"filter" => ""})
    state = %{socket.assigns.list_state | page_size: 10}
    page = Reads.plans_page(mount, scope, state)
    assert length(page.items) == 10
    assert page.has_more

    next = Reads.plans_page(mount, scope, %{state | cursor: page.next_cursor})
    assert length(next.items) == 2
    refute next.has_more
  end

  test "zero rows render the kit-default empty_state" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)
    assert socket.assigns.page.items == []
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt) — no write affordance in the DOM
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no create/toggle/delete affordance; the plan list still renders" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the seeded plan row renders (plans are non-PII).
    assert rendered =~ "plan-row"
    assert rendered =~ "Growth"
    refute rendered =~ ~s(phx-click="new_plan")
    refute rendered =~ ~s(phx-click="toggle_plan")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    refute rendered =~ "vt_"
  end
end
