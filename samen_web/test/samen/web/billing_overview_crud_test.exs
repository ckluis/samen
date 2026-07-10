defmodule Samen.Web.BillingOverviewCrudTest do
  @moduledoc """
  A3 WIRING (billing-support batch) — the WRITE side of `Samen.Web.Billing.OverviewLive`
  (🔒 PII: the Customer's `billing_name` / `billing_email` are vault-routed scalars —
  this is the billing batch's NEW PII WRITE SURFACE):

    * **CRUD (AC-G1-1/2)** — "New customer" is a REAL button opening the modal +
      `simple_form` (the vaulted name/email fields render through the kit
      `form_field/1`); an INVALID submit renders inline errors and persists NOTHING;
      a VALID submit persists + refreshes the bounded subscription list; each
      subscription row carries `delete_confirm/1` (FAIL-HONEST FK refusal for a
      subscription with invoices).
    * **MC-2 (vault write chokepoint)** — the tenant-created billing_name/billing_email
      are NOT plaintext at rest: the raw (resolver-bypassing) record carries no
      sentinel fragment.
    * **MC-1 / RP-G1-7 (the write-path red path)** — an operator-plane submit carrying
      plaintext billing PII is REJECTED at the Ash write path (`Samen.Pii.WriteGuard`);
      DB unchanged. The affordance is also absent from the operator DOM (belt), but the
      red path drives the HANDLER directly (anti-tautology: the SAME submit on the
      tenant plane succeeds — the rejection discriminates on the plane).
    * **Bounded read (AC-G1-5)** — `subscriptions_page/3` passes `bounded!/4`
      non-vacuously; keyset pagination walks the set on the real page.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Billing.OverviewLive
  alias Samen.Web.Billing.Reads
  alias Samen.Web.ListLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads

  @sentinel_name "Vaultbound Plaintext Cartage"
  @sentinel_email "vaultbound.plaintext@example.test"

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> OverviewLive.load(org_id)
  end

  defp html(socket), do: render_html(OverviewLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = OverviewLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp customer_count(org_id) do
    Samen.WebTest.Billing.Customer
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp customers_of(org_id) do
    Samen.WebTest.Billing.Customer
    |> Ash.Query.ensure_selected([:org_id, :billing_name, :billing_email])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp seed_subscription(org_id) do
    customer =
      Samen.WebTest.Billing.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, billing_name: "Sub Fixture Co", status: :active},
        authorize?: false
      )
      |> Ash.create!()

    Samen.WebTest.Billing.Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, customer_id: customer.id, status: :active},
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # Create — green path (AC-G1-1/2 + MC-2)
  # ---------------------------------------------------------------------------

  test "New customer opens the modal; a VALID submit persists and vault-routes name/email (MC-2)" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="new-customer")
    assert rendered =~ ~s(phx-click="new_customer")

    socket = event(socket, "new_customer", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-customer-form")
    assert rendered =~ ~s(name="form[billing_name]")
    assert rendered =~ ~s(name="form[billing_email]")

    socket =
      event(socket, "save_new", %{
        "form" => %{"billing_name" => @sentinel_name, "billing_email" => @sentinel_email, "currency" => "USD"}
      })

    refute socket.assigns.show_new
    assert customer_count(org_id) == 1

    # MC-2: the vaulted fields are NOT plaintext at rest — the raw record (no
    # resolver) carries no sentinel fragment. A vault bypass would FAIL here.
    [raw] = customers_of(org_id)
    refute inspect(raw.billing_name) =~ "Vaultbound"
    refute inspect(raw.billing_email) =~ "vaultbound.plaintext"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (garbage status) shows inline errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id) |> event("new_customer", %{})

    socket =
      event(socket, "save_new", %{"form" => %{"billing_name" => "Half Customer", "status" => "not-a-status"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert customer_count(org_id) == 0
  end

  # ---------------------------------------------------------------------------
  # Delete — subscription rows (fail-honest FK)
  # ---------------------------------------------------------------------------

  test "delete destroys a bare subscription; one with linked invoices is REFUSED and surfaced" do
    %{org_id: org_id, billing: %{subscription: linked_sub}} = Seeds.seed_all()
    bare_sub = seed_subscription(org_id)

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert rendered =~ ~s(phx-value-id="#{bare_sub.id}")

    socket = event(socket, "delete", %{"id" => bare_sub.id})
    ids = Enum.map(socket.assigns.page.items, & &1.id)
    refute bare_sub.id in ids

    # FAIL-HONEST: the seeded subscription carries an invoice (FK) — refused, surfaced.
    socket = event(socket, "delete", %{"id" => linked_sub.id})
    assert linked_sub.id in Enum.map(socket.assigns.page.items, & &1.id)
    assert html(socket) =~ "Could not delete this subscription"
  end

  # ---------------------------------------------------------------------------
  # MC-1 / RP-G1-7 — the operator plane: DOM belt + write-path suspenders
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no write affordance in the DOM; the subscription list renders masked (belt)" do
    %{org_id: org_id} = Seeds.seed_all()
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    rendered = html(socket)
    # Non-vacuous: the seeded subscription row renders, masked.
    assert rendered =~ "subscription-row"
    assert rendered =~ "••••"
    refute rendered =~ Seeds.customer_name()
    refute rendered =~ Seeds.customer_email()
    refute rendered =~ ~s(phx-click="new_customer")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    refute rendered =~ "vt_"
  end

  test "RED PATH (MC-1 / RP-G1-7): an operator-plane create with plaintext billing PII is REJECTED; DB unchanged" do
    org_id = Ash.UUID.generate()
    before_count = customer_count(org_id)

    # Drive the HANDLER directly on an operator-plane socket — the enforcement under
    # test is Samen.Pii.WriteGuard on the Ash write path, NOT the hidden button.
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)

    socket =
      event(socket, "save_new", %{
        "form" => %{"billing_name" => "Operator Authored Billing", "billing_email" => "operator.authored@example.test"}
      })

    assert customer_count(org_id) == before_count
    assert AshPhoenix.Form.errors(socket.assigns.new_form.source) != []

    assert socket.assigns.new_form.source
           |> AshPhoenix.Form.errors()
           |> inspect() =~ "no-operator-plaintext-write"
  end

  test "ANTI-TAUTOLOGY pairing: the SAME submit on the TENANT plane succeeds — the rejection discriminates on the plane" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    _socket =
      event(socket, "save_new", %{
        "form" => %{"billing_name" => "Operator Authored Billing", "billing_email" => "operator.authored@example.test"}
      })

    assert customer_count(org_id) == 1
  end

  # ---------------------------------------------------------------------------
  # Bounded read + pagination (AC-G1-5 / RP-G1-5 per-surface)
  # ---------------------------------------------------------------------------

  test "subscriptions_page/3 is BOUNDED (bounded!/4 non-vacuous) and keyset pagination walks the real page" do
    org_id = Ash.UUID.generate()
    for _ <- 1..12, do: seed_subscription(org_id)
    mount = build_mount(:billing)
    scope = Mount.scope(mount, org_id)

    assert :ok == WebReads.bounded!(&Reads.subscriptions_page/3, mount, scope, page_size: 10)

    page = Reads.subscriptions_page(mount, scope, %Samen.Web.ListState{page_size: 10, sort: {:status, :asc}})
    assert length(page.items) == 10
    assert page.has_more
    # The joins survived paging (customer resolved per plane — tenant clear).
    assert Enum.all?(page.items, &(&1.__customer__ != nil))

    next = Reads.subscriptions_page(mount, scope, %Samen.Web.ListState{page_size: 10, sort: {:status, :asc}, cursor: page.next_cursor})
    assert length(next.items) == 2
    refute next.has_more

    # And the real page walks with the mixin events.
    socket = mount_socket(org_id)
    assert length(socket.assigns.page.items) == 12
    socket = list_event(socket, "sort", %{"field" => "status"})
    assert socket.assigns.list_state.sort == {:status, :desc}
  end
end
