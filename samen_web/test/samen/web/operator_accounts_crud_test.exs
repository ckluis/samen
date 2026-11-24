defmodule Samen.Web.OperatorAccountsCrudTest do
  @moduledoc """
  A3 WIRING (operator batch) — `Samen.Web.Operator.AccountsLive` on the A2 kit contract
  (`ListLive` + `list_view` + `simple_form`/`modal`). The account row is a non-PII `Org`
  (name/plan/slug — ADR-010 §8.3); the PII-bearing joins (tenant-admin name/email) are
  proven CLEAR/masked in `operator_accounts_render_test.exs` + the identity-line test,
  which exercise the SAME render path.

    * **CRUD (AC-G1-1/2)** — "New account" is a REAL button opening the modal +
      `simple_form` over the Identity `Org` CREATE (the one sanctioned account write);
      an INVALID submit (missing required name) renders inline errors and persists
      NOTHING; a VALID submit persists + refreshes the bounded list. There is
      deliberately NO account delete (the Org anchor's destroy is `OrgIsSelf`-gated;
      the domain defines no operator offboarding action) — asserted absent.
    * **Bounded read (AC-G1-5)** — `accounts_page/3` passes `bounded!/4` non-vacuously;
      a 55-account book NEVER loads the full set; keyset next/prev + sort + filter work
      on the REAL page; the sort red path refuses an undeclared field.
    * **Impersonation-plane posture (belt)** — a `plane: :operator` mount renders NO
      write affordance (`Samen.Web.Operator.Live.writable?/1`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.ListLive
  alias Samen.Web.Operator.AccountsLive
  alias Samen.Web.Operator.Reads
  alias Samen.Web.Reads, as: WebReads
  alias Samen.WebTest.Operator, as: Op

  # -- harness -------------------------------------------------------------------

  # A LIGHT operator book: just the operator Org anchor (well-known id), no heavy
  # cross-namespace seed — these tests exercise the Org list + create, not the joins.
  defp seed_operator_org do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc."}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:plan, "operator")
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:org_id, org.id)
    |> Ash.update!()
  end

  defp seed_accounts(operator_org_id, n) do
    for i <- 1..n do
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Account #{String.pad_leading(to_string(i), 2, "0")}"},
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(:org_id, operator_org_id)
      |> Ash.Changeset.force_change_attribute(:plan, "growth")
      |> Ash.create!()
    end
  end

  # `role` is the AUTHENTICATED operator role `Samen.Web.Operator.Authz`'s on_mount assigns (never a param).
  defp mount_socket(mount, role \\ :operator_admin) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_operator_role, role)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> AccountsLive.load()
  end

  defp html(socket), do: render_html(AccountsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = AccountsLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp account_count(operator_org_id) do
    Op.Org
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == operator_org_id and &1.id != operator_org_id))
  end

  # ---------------------------------------------------------------------------
  # Create — green + red (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New account opens the modal; a VALID submit persists and refreshes the bounded list" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id, labels: %{plan_labels: {__MODULE__, :offered_plans, []}}))

    rendered = html(socket)
    assert rendered =~ ~s(id="new-account")
    assert rendered =~ ~s(phx-click="new_account")

    socket = event(socket, "new_account", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-account-form")
    assert rendered =~ ~s(name="form[name]")

    socket = event(socket, "save_new", %{"form" => %{"name" => "Cascade Freight Co", "plan" => "growth"}})

    refute socket.assigns.show_new
    assert account_count(op.id) == 1
    rendered = html(socket)
    assert rendered =~ "Cascade Freight Co"
  end

  # ---------------------------------------------------------------------------
  # Write gate (identity-authz review 2, finding 2): the operator WRITE roles only, a plan the host offers, a free slug
  # ---------------------------------------------------------------------------

  def offered_plans(_org_id), do: [%{key: "starter", label: "Starter"}, %{key: "growth", label: "Growth"}]

  defp save(socket, form), do: socket |> event("new_account", %{}) |> event("save_new", %{"form" => form})

  test "RED: a read-only operator pushing save_new creates NOTHING; CONTROL: admin and support operators create" do
    op = seed_operator_org()

    for role <- [:operator_readonly, nil, :bogus] do
      socket = save(mount_socket(build_operator_mount(op.id), role), %{"name" => "Sneaky Co"})
      assert account_count(op.id) == 0, "role #{inspect(role)} must not create an account"
      assert socket.assigns.flash["error"] =~ "permission"
    end

    for {role, name} <- [operator_admin: "Admin Co", operator_support: "Support Co"] do
      socket = save(mount_socket(build_operator_mount(op.id), role), %{"name" => name})
      refute socket.assigns.show_new
    end

    assert account_count(op.id) == 2
  end

  test "RED: a plan the host does not offer is refused; CONTROL: an offered plan (and a blank one) is accepted" do
    op = seed_operator_org()

    # no :plan_labels hook wired: the host offers no plan, so none can be named (blank = the column default)
    bare = mount_socket(build_operator_mount(op.id))
    assert account_count(op.id) == 0
    socket = save(bare, %{"name" => "Free Text Co", "plan" => "enterprise-free-forever"})
    assert socket.assigns.show_new
    assert account_count(op.id) == 0
    socket = save(bare, %{"name" => "Default Co", "plan" => ""})
    refute socket.assigns.show_new
    assert account_count(op.id) == 1

    mount = build_operator_mount(op.id, labels: %{plan_labels: {__MODULE__, :offered_plans, []}})
    socket = save(mount_socket(mount), %{"name" => "Forged Plan Co", "plan" => "enterprise-free-forever"})
    assert socket.assigns.show_new
    assert account_count(op.id) == 1
    socket = save(mount_socket(mount), %{"name" => "Growth Co", "plan" => "growth"})
    refute socket.assigns.show_new
    assert account_count(op.id) == 2
  end

  test "RED: a slug that is an existing org's id or an existing account's slug is refused; CONTROL: a fresh slug is accepted" do
    op = seed_operator_org()
    [existing] = seed_accounts(op.id, 1)

    existing
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:slug, "taken-slug")
    |> Ash.update!()

    mount = build_operator_mount(op.id, labels: %{plan_labels: {__MODULE__, :offered_plans, []}})

    for slug <- [op.id, existing.id, "taken-slug"] do
      socket = save(mount_socket(mount), %{"name" => "Forged Name", "slug" => slug})
      assert socket.assigns.show_new, "slug #{slug} must be refused"
    end

    assert account_count(op.id) == 1
    socket = save(mount_socket(mount), %{"name" => "Honest Co", "slug" => "fresh-slug"})
    refute socket.assigns.show_new
    assert account_count(op.id) == 2
  end

  test "RED PATH (AC-G1-2): an INVALID submit (missing required name) shows inline errors and persists NOTHING" do
    op = seed_operator_org()
    socket =
      mount_socket(build_operator_mount(op.id, labels: %{plan_labels: {__MODULE__, :offered_plans, []}}))
      |> event("new_account", %{})

    socket = event(socket, "save_new", %{"form" => %{"name" => "", "plan" => "growth"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert account_count(op.id) == 0
    assert socket.assigns.page.items == []
  end

  test "NO account delete is offered — the domain defines no operator offboarding action" do
    op = seed_operator_org()
    seed_accounts(op.id, 1)
    rendered = html(mount_socket(build_operator_mount(op.id)))

    assert rendered =~ "account-row"
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
  end

  # ---------------------------------------------------------------------------
  # Bounded read + list ergonomics on the REAL page (AC-G1-5 / AC-G1-3)
  # ---------------------------------------------------------------------------

  test "a 55-account book NEVER loads the full set; keyset next/prev, sort, and filter work; undeclared sort refused" do
    op = seed_operator_org()
    seed_accounts(op.id, 55)
    mount = build_operator_mount(op.id)
    scope = Samen.Web.Operator.scope(mount)

    assert :ok == WebReads.bounded!(&Reads.accounts_page/3, mount, scope, page_size: 10)

    socket = mount_socket(mount)
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more
    refute html(socket) =~ "Account 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert length(socket.assigns.page.items) == 5
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()

    # Sort toggle + the undeclared-field red path (no atom minting).
    socket = list_event(socket, "sort", %{"field" => "name"})
    assert socket.assigns.list_state.sort == {:name, :desc}
    before_state = socket.assigns.list_state
    socket = list_event(socket, "sort", %{"field" => "slug"})
    assert socket.assigns.list_state == before_state

    # Filter narrows server-side.
    socket = list_event(socket, "filter", %{"filter" => "Account 07"})
    assert Enum.map(socket.assigns.page.items, & &1.name) == ["Account 07"]
  end

  test "zero accounts render the kit-default empty_state" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id))
    assert socket.assigns.page.items == []
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Impersonation-plane posture (belt — the enforcement is the kernel's)
  # ---------------------------------------------------------------------------

  test "OPERATOR (impersonation) plane mount: no write affordance; the list still renders" do
    op = seed_operator_org()
    seed_accounts(op.id, 1)

    mount =
      Samen.Web.Mount.new(
        :operator,
        Samen.WebTest.Operator,
        Samen.WebTest.Repo,
        plane: Samen.Web.Plane.operator("op-1", op.id, "test-session"),
        labels: %{operator_org_id: op.id}
      )

    rendered = html(mount_socket(mount))

    # Non-vacuous: the account row renders (Org name is non-PII).
    assert rendered =~ "account-row"
    assert rendered =~ "Account 01"
    refute rendered =~ ~s(phx-click="new_account")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "vt_"
  end
end
