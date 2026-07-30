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

  require Ash.Query

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

  # T37a: archived Plan rows are excluded from the default read/get (ADR-040 §5.5) —
  # fetch through the `:archived` trash read instead, mirroring T36's soft_delete_test.
  defp archived_plan(id) do
    Samen.WebTest.Billing.Plan
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
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

  test "delete soft-archives a bare plan AND a plan with linked prices (no FK refusal — ADR-040 §5.4 declares no cascade)" do
    %{org_id: org_id, billing: %{plan: linked_plan}} = Seeds.seed_all()
    [bare_plan] = seed_plans(org_id, 1)

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{bare_plan.id}")

    socket = event(socket, "delete", %{"id" => bare_plan.id})
    # `plan_count/1` reads through the default (archived-excluding) filter — the
    # archived bare plan simply drops out, same observable shape as the old hard
    # delete for THIS assertion, even though the row still exists (T36 soft-destroy).
    assert plan_count(org_id) == 1
    refute html(socket) =~ "plan-#{bare_plan.name}"
    assert Samen.Info.archivable?(Samen.WebTest.Billing.Plan)
    assert archived_plan(bare_plan.id).archived_at

    # ADR-040 §5.9/T37a: `Plan` is `archivable true` — the default `:destroy` is now
    # T36's soft-destroy (sets `archived_at`, never a real row removal), and billing
    # declares NO cascade (§5.4). A plan with linked prices/subscriptions is no
    # longer refused by a Postgres FK — the destroy succeeds, archives the plan, and
    # its live children (untouched, still pointing at the now-hidden plan_id) are
    # not deleted or blocked.
    socket = event(socket, "delete", %{"id" => linked_plan.id})
    assert plan_count(org_id) == 0
    refute html(socket) =~ "Could not delete this plan"
    assert archived_plan(linked_plan.id).archived_at

    # The linked plan's Price rows are untouched (no cascade) — still live and still
    # pointing at the now-archived plan.
    assert Samen.WebTest.Billing.Price
           |> Ash.Query.filter(plan_id == ^linked_plan.id)
           |> Ash.read!(authorize?: false)
           |> Enum.any?()
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

  # ---------------------------------------------------------------------------
  # T37h (ADR-040 §5.8) — archive/restore/archived-filter toggle, on the reference
  # resource. The toggle + restore events ride `Samen.Web.ListLive` (framework-level,
  # T37h) — this is the SAME mixin `handle_list_event/3` `select`/`sort`/etc. already
  # use, not a hand-rolled `handle_event` clause on `PlansLive` itself.
  # ---------------------------------------------------------------------------

  describe "T37h — archive → hidden → toggle shows it → restore → visible again" do
    test "the toggle button is a REAL affordance and starts OFF (archived rows hidden by default)" do
      org_id = Ash.UUID.generate()
      socket = mount_socket(org_id)

      refute socket.assigns.list_state.show_archived
      rendered = html(socket)
      assert rendered =~ ~s(phx-click="toggle_archived")
      assert rendered =~ "Show archived"
    end

    test "an archived plan is hidden by default, appears (with a Restore action, not Edit/Delete) once toggled on, and restore returns it to the live view" do
      org_id = Ash.UUID.generate()
      [plan] = seed_plans(org_id, 1)

      socket = mount_socket(org_id) |> event("delete", %{"id" => plan.id})
      assert archived_plan(plan.id).archived_at

      # Default (toggle OFF): the archived plan is hidden — the existing E6 substrate
      # guarantee (§5.5's ExcludeArchived preparation), unchanged by this task.
      refute html(socket) =~ ~s(phx-value-id="#{plan.id}")

      # Toggle ON: the archived-filter switches Reads.plans_page/3 to the `:archived`
      # read — a TRASH view (archived rows ONLY, Samen.Archival.OnlyArchived; NOT a
      # union with the live set — "View: live | archived", a filter switch, not a
      # merge). The row appears, marked, with Restore (not Edit/Disable/Delete —
      # those don't make sense on an archived row).
      socket = list_event(socket, "toggle_archived", %{})
      assert socket.assigns.list_state.show_archived
      rendered = html(socket)
      assert rendered =~ ~s(phx-value-id="#{plan.id}")
      assert rendered =~ "archived"
      assert rendered =~ ~s(phx-click="restore" phx-value-id="#{plan.id}")
      refute rendered =~ ~s(phx-click="edit_plan" phx-value-id="#{plan.id}")
      refute rendered =~ ~s(phx-click="delete" phx-value-id="#{plan.id}")

      # Restore — through the mixin's `restore` event (Samen.Archival.restore/2,
      # scoped via Reads.elevate_to_admin/1 — Plan writes are RoleAtLeast :admin,
      # never authorize?: false). FAIL-HONEST: only fires because Plan IS
      # Samen.Info.archivable?/1 (a non-archivable resource's `restore` is a no-op —
      # proved below in its own test).
      socket = list_event(socket, "restore", %{"id" => plan.id})
      restored = Ash.get!(Samen.WebTest.Billing.Plan, plan.id, authorize?: false)
      refute restored.archived_at

      # Still viewing the TRASH (toggle still ON): the now-live row graduated OUT of
      # the archived-only view — it is gone from THIS list, not shown with new actions.
      refute html(socket) =~ ~s(phx-value-id="#{plan.id}")

      # Toggle back OFF — the restored plan is a normal live row again, with the
      # usual Edit/Disable/Delete actions, no Restore/archived pill.
      socket = list_event(socket, "toggle_archived", %{})
      refute socket.assigns.list_state.show_archived
      rendered = html(socket)
      assert rendered =~ ~s(phx-click="edit_plan" phx-value-id="#{plan.id}")
      refute rendered =~ ~s(phx-click="restore" phx-value-id="#{plan.id}")
    end

    test "restoring a resource that is NOT archivable is a structural no-op (FAIL-HONEST, never a crash)" do
      # Positive control for the mixin's own fail-honest guard (§5.8): a `restore`
      # event against a resource lacking `archivable: true` neither raises nor
      # mutates anything. `Samen.WebTest.Billing.Customer` (the billing-mirror
      # exclusion, ADR-040 §5.9) is a real non-archivable resource in the SAME
      # fixture host `PlansLive` uses — `NonArchivableListLiveFixture` mounts it on
      # the exact same mixin, so this exercises the REAL `handle_list_event/3` path
      # (`view.__list_config__/0` included), not a hand-rolled substitute.
      refute Samen.Info.archivable?(Samen.WebTest.Billing.Customer)

      org_id = Ash.UUID.generate()

      {:ok, customer} =
        Samen.WebTest.Billing.Customer
        |> Ash.Changeset.for_create(:create, %{org_id: org_id}, authorize?: false)
        |> Ash.create()

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:samen_list_ctx, %{
          view: NonArchivableListLiveFixture,
          mount: build_mount(:billing),
          scope: Mount.scope(build_mount(:billing), org_id)
        })
        |> Phoenix.Component.assign(:list_state, %Samen.Web.ListState{})
        |> Phoenix.Component.assign(:page, %Samen.Web.Page{items: [customer]})

      assert {:noreply, ^socket} = ListLive.handle_list_event("restore", %{"id" => customer.id}, socket)

      # No mutation: the Customer row is exactly as it was (no `archived_at` to set —
      # it has none — and no error either).
      assert Ash.get!(Samen.WebTest.Billing.Customer, customer.id, authorize?: false).id == customer.id
    end
  end
end

# A minimal `Samen.Web.ListLive`-mounted fixture over a genuinely NON-archivable
# resource (`Samen.WebTest.Billing.Customer`) — proves the `restore` event's
# fail-honest guard (`config.resource && Samen.Info.archivable?/1`) against a REAL
# `__list_config__/0`, not a hand-rolled stand-in for one.
defmodule NonArchivableListLiveFixture do
  @moduledoc false

  # Deliberately UNALIASED bare `Customer` — matching the SAME host-agnostic-name
  # convention `Samen.Web.Billing.PlansLive` uses for `resource: Plan` (also
  # deliberately unaliased there). `Samen.Web.Mount.resource/2` (`Module.concat/2`,
  # via `Module.split/1`) resolves the BARE trailing name against the mount's
  # namespace at runtime — `Module.concat(ns, Elixir.Customer)` -> `ns.Customer`.
  # An ALIASED (fully-qualified) reference here would double-qualify and resolve to
  # nothing (confirmed the hard way — see T37h's evidence.txt).
  use Samen.Web.ListLive,
    resource: Customer,
    reads: &__MODULE__.empty_page/3,
    sortable: [:id]

  @doc false
  def empty_page(_mount, _scope, _state), do: %Samen.Web.Page{items: []}
end
