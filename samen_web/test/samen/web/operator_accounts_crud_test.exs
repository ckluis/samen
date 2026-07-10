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
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc.", plan: "operator"}, authorize?: false)
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{org_id: org.id}, authorize?: false)
    |> Ash.update!()
  end

  defp seed_accounts(operator_org_id, n) do
    for i <- 1..n do
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          name: "Account #{String.pad_leading(to_string(i), 2, "0")}",
          plan: "growth"
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp mount_socket(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
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
    socket = mount_socket(build_operator_mount(op.id))

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

  test "RED PATH (AC-G1-2): an INVALID submit (missing required name) shows inline errors and persists NOTHING" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id)) |> event("new_account", %{})

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
