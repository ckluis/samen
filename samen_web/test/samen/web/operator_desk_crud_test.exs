defmodule Samen.Web.OperatorDeskCrudTest do
  @moduledoc """
  A3 WIRING (operator batch) — `Samen.Web.Operator.DeskLive` on the A2 kit contract
  (`ListLive` + `list_view` + `simple_form`/`modal`/`delete_confirm`). The desk is a
  PII-TOUCHING surface (the requester is a tenant-admin `Identity.User` — vaulted
  `full_name`/`emails`), so this file carries the per-plane masking tests alongside
  the CRUD wiring proofs:

    * **CRUD (AC-G1-1/2)** — "New ticket" is a REAL button opening the modal +
      `simple_form` over the support blueprint's `Ticket` CREATE (`subject` required —
      the inline-error path is real); an INVALID submit renders inline errors and
      persists NOTHING; a VALID submit persists + refreshes the bounded list; each row
      carries `delete_confirm/1`; a bare ticket deletes through Ash; a ticket with a
      linked conversation now ARCHIVES (ADR-040 §5.9/T37f: `Ticket` is `archivable
      true`, the cascade PARENT of `ticket ▸cascade conversation ▸cascade message`,
      §5.4), cascading the archive to its conversation/message at the same instant,
      superseding the old hard-delete FK-refusal.
    * **Bounded read (AC-G1-5 / AC-G1-3)** — `desk_page/3` passes `bounded!/4`
      non-vacuously; a 55-ticket desk NEVER loads the full set; keyset next/prev +
      sort + filter work on the REAL page; the sort red path refuses an undeclared
      field; zero tickets render the kit-default `empty_state`.
    * **Per-plane masking (AC-G1-7 posture + the identity line)** — the operator's
      OWN workspace (tenant plane) renders the requester CLEAR (population 1, the
      SaaS's own customer — proven in `operator_desk_render_test.exs` on the SAME
      seed); a `plane: :operator` (impersonation) mount of the SAME surface renders
      the requester `••••` with NO write affordance and NO token leak — the
      plane-aware `Samen.Web.Operator.scope/1` fails MASKED, never clear.
    * **MC-1 / RP-G1-7 (the write-guard red path)** — an operator-plane actor writing
      plaintext into the requester's vaulted `full_name` is REJECTED at the Ash write
      path (`Samen.Pii.WriteGuard`), DB unchanged. The desk's own sanctioned writes
      (`Ticket` create/destroy) carry no vaulted attrs, so the red path drives the
      write path of the PII resource the surface RENDERS — proving the enforcement is
      the kernel's, not a hidden button (anti-tautology: the SAME write on the tenant
      plane succeeds and vault-routes, so the rejection discriminates on the plane).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.ListLive
  alias Samen.Web.Operator.DeskLive
  alias Samen.Web.Operator.Reads
  alias Samen.Web.Reads, as: WebReads
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  # -- harness -------------------------------------------------------------------

  # A LIGHT operator book for the CRUD/list tests: just the operator Org anchor —
  # these exercise the Ticket list + create/delete, not the PII joins.
  defp seed_operator_org do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc.", plan: "operator"}, authorize?: false)
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{org_id: org.id}, authorize?: false)
    |> Ash.update!()
  end

  defp seed_tickets(operator_org_id, n) do
    for i <- 1..n do
      Op.Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          subject: "Ticket #{String.pad_leading(to_string(i), 2, "0")}",
          status: :open,
          priority: :normal
        },
        actor: %{org_id: operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp mount_socket(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> DeskLive.load()
  end

  defp html(socket), do: render_html(DeskLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = DeskLive.handle_event(name, params, socket)
    socket
  end

  defp list_event(socket, name, params) do
    {:noreply, socket} = ListLive.handle_list_event(name, params, socket)
    socket
  end

  defp ticket_count(operator_org_id) do
    Op.Ticket
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == operator_org_id))
  end

  defp impersonation_mount(operator_org_id) do
    Samen.Web.Mount.new(
      :operator,
      Samen.WebTest.Operator,
      Samen.WebTest.Repo,
      plane: Samen.Web.Plane.operator("op-1", operator_org_id, "test-session"),
      labels: %{operator_org_id: operator_org_id}
    )
  end

  # ---------------------------------------------------------------------------
  # Create — green + red (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "New ticket opens the modal; a VALID submit persists and refreshes the bounded list" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id))

    rendered = html(socket)
    assert rendered =~ ~s(id="new-desk-ticket")
    assert rendered =~ ~s(phx-click="new_ticket")

    socket = event(socket, "new_ticket", %{})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="new-desk-ticket-form")
    assert rendered =~ ~s(name="form[subject]")
    assert rendered =~ ~s(name="form[priority]")

    socket = event(socket, "save_new", %{"form" => %{"subject" => "SSO login loops forever", "priority" => "high"}})

    refute socket.assigns.show_new
    assert ticket_count(op.id) == 1
    assert html(socket) =~ "SSO login loops forever"
  end

  test "RED PATH (AC-G1-2): an INVALID submit (missing required subject) shows inline errors and persists NOTHING" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id)) |> event("new_ticket", %{})

    socket = event(socket, "save_new", %{"form" => %{"subject" => "", "priority" => "normal"}})

    assert socket.assigns.show_new
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert ticket_count(op.id) == 0
    assert socket.assigns.page.items == []
  end

  # ---------------------------------------------------------------------------
  # Delete — the interlocked row action, FAIL-HONEST on linked records
  # ---------------------------------------------------------------------------

  test "each row carries the delete_confirm interlock; a bare ticket deletes through Ash and refreshes" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id)) |> event("new_ticket", %{})
    socket = event(socket, "save_new", %{"form" => %{"subject" => "Doomed row", "priority" => "low"}})

    [ticket] = socket.assigns.page.items

    rendered = html(socket)
    assert rendered =~ "data-confirm"
    assert rendered =~ ~s(phx-value-id="#{ticket.id}")

    socket = event(socket, "delete", %{"id" => ticket.id})
    assert socket.assigns.page.items == []
    assert ticket_count(op.id) == 0
    assert html(socket) =~ "empty-state"
  end

  test "ADR-040 §5.9/T37f: deleting a ticket with a linked conversation ARCHIVES it, cascading to its conversation/message" do
    seed = OpSeeds.seed_all(tenants: 1)
    [%{tickets: [ticket | _]} | _] = seed.accounts
    before_count = ticket_count(seed.operator_org_id)

    linked_conversation =
      Samen.WebTest.Operator.Conversation
      |> Ash.Query.filter(ticket_id == ^ticket.id)
      |> Ash.read_one!(authorize?: false)

    linked_message =
      Samen.WebTest.Operator.Message
      |> Ash.Query.filter(conversation_id == ^linked_conversation.id)
      |> Ash.read_one!(authorize?: false)

    socket = mount_socket(build_operator_mount(seed.operator_org_id))
    socket = event(socket, "delete", %{"id" => ticket.id})

    # No refusal — the ticket archives, cascading to its conversation/message.
    refute socket.assigns.delete_error
    assert ticket_count(seed.operator_org_id) == before_count - 1
    refute Enum.any?(socket.assigns.page.items, &(&1.id == ticket.id))

    live_conversation_ids =
      Samen.WebTest.Operator.Conversation
      |> Ash.Query.ensure_selected([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    live_message_ids =
      Samen.WebTest.Operator.Message
      |> Ash.Query.ensure_selected([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    refute linked_conversation.id in live_conversation_ids
    refute linked_message.id in live_message_ids
  end

  # ---------------------------------------------------------------------------
  # Bounded read + list ergonomics on the REAL page (AC-G1-5 / AC-G1-3)
  # ---------------------------------------------------------------------------

  test "a 55-ticket desk NEVER loads the full set; keyset next/prev, sort, and filter work; undeclared sort refused" do
    op = seed_operator_org()
    seed_tickets(op.id, 55)
    mount = build_operator_mount(op.id)
    scope = Samen.Web.Operator.scope(mount)

    assert :ok == WebReads.bounded!(&Reads.desk_page/3, mount, scope, page_size: 10)

    socket = mount_socket(mount)
    assert length(socket.assigns.page.items) == WebReads.default_page_size()
    assert socket.assigns.page.has_more
    refute html(socket) =~ "Ticket 51"

    socket = list_event(socket, "paginate", %{"dir" => "next"})
    assert length(socket.assigns.page.items) == 5
    refute socket.assigns.page.has_more

    socket = list_event(socket, "paginate", %{"dir" => "prev"})
    assert length(socket.assigns.page.items) == WebReads.default_page_size()

    # Sort toggle + the undeclared-field red path (no atom minting).
    socket = list_event(socket, "sort", %{"field" => "subject"})
    assert socket.assigns.list_state.sort == {:subject, :desc}
    before_state = socket.assigns.list_state
    socket = list_event(socket, "sort", %{"field" => "sla_breach_at"})
    assert socket.assigns.list_state == before_state

    # Filter narrows server-side.
    socket = list_event(socket, "filter", %{"filter" => "Ticket 07"})
    assert Enum.map(socket.assigns.page.items, & &1.subject) == ["Ticket 07"]
  end

  test "zero tickets render the kit-default empty_state" do
    op = seed_operator_org()
    socket = mount_socket(build_operator_mount(op.id))
    assert socket.assigns.page.items == []
    assert html(socket) =~ "empty-state"
  end

  # ---------------------------------------------------------------------------
  # Per-plane masking — the desk renders PII (the requester), so the operator
  # (impersonation) plane must stay •••• with NO write affordance (belt), while the
  # tenant-plane clear side rides operator_desk_render_test.exs on the SAME seed.
  # ---------------------------------------------------------------------------

  test "OPERATOR (impersonation) plane: the SAME desk renders the requester ••••, offers NO write affordance, leaks NO token" do
    seed = OpSeeds.seed_all(tenants: 1)
    rendered = html(mount_socket(impersonation_mount(seed.operator_org_id)))

    # Non-vacuous: the ticket rows render (subject is non-PII)…
    assert rendered =~ "desk-ticket-row"
    assert rendered =~ "Cannot invite a second admin"
    # …but the requester's vaulted PII is MASKED — the plane-aware scope fails
    # masked, never clear (Samen.Web.Operator.scope/1 A3 clause).
    assert rendered =~ "••••"
    refute rendered =~ OpSeeds.admin_full_name()
    refute rendered =~ OpSeeds.admin_email()
    # No write affordance on the impersonation plane (writable?/1 belt)…
    refute rendered =~ ~s(phx-click="new_ticket")
    refute rendered =~ ~s(phx-click="delete")
    refute rendered =~ "data-confirm"
    # …and no vault-token leak through the (hidden) form plumbing.
    refute rendered =~ "vt_"
  end

  # ---------------------------------------------------------------------------
  # MC-1 / RP-G1-7 — the operator plane exercises Samen.Pii.WriteGuard on the
  # PII resource this surface renders (the requester Identity.User).
  # ---------------------------------------------------------------------------

  test "RED PATH (MC-1 / RP-G1-7): an operator-plane plaintext write to the requester's vaulted full_name is REJECTED; DB unchanged" do
    seed = OpSeeds.seed_all(tenants: 1)
    [%{admin: admin} | _] = seed.accounts

    # The ADR-009 operator-plane actor — the SAME shape Plane.scope/2 builds. The write
    # is driven at the Ash write path with authorization off, so the ONLY thing standing
    # between the operator and the tenant-admin's vault is Samen.Pii.WriteGuard.
    operator_actor = Samen.Web.Plane.scope(
      Samen.Web.Plane.operator("op-1", seed.operator_org_id, "test-session"),
      seed.operator_org_id
    ).actor

    result =
      Op.User
      |> Ash.get!(admin.id, authorize?: false)
      |> Ash.Changeset.for_update(
        :update,
        %{full_name: %Samen.Type.FullName{first: "Operator", last: "Authored"}},
        actor: operator_actor,
        authorize?: false
      )
      |> Ash.update()

    assert {:error, error} = result
    assert inspect(error) =~ "no-operator-plaintext-write"

    # DB provably unchanged: the raw (resolver-bypassing) record carries no trace of
    # the operator-authored plaintext.
    raw = Ash.get!(Op.User, admin.id, authorize?: false)
    refute inspect(raw.full_name) =~ "Authored"
  end

  test "ANTI-TAUTOLOGY pairing: the SAME write under a TENANT-plane actor succeeds AND vault-routes (MC-2) — the rejection discriminates on the plane" do
    seed = OpSeeds.seed_all(tenants: 1)
    [%{admin: admin} | _] = seed.accounts

    tenant_actor = Samen.Web.Operator.scope(build_operator_mount(seed.operator_org_id)).actor
    assert tenant_actor.plane == :tenant

    updated =
      Op.User
      |> Ash.get!(admin.id, authorize?: false)
      |> Ash.Changeset.for_update(
        :update,
        %{full_name: %Samen.Type.FullName{first: "Tenant", last: "Renamed"}},
        actor: tenant_actor,
        authorize?: false
      )
      |> Ash.update!()

    # If the guard rejected regardless of plane (over-block) this would fail; if it
    # never rejected (tautology) the operator red path above would fail instead.
    # MC-2: the accepted write is vault-routed — NOT plaintext at rest.
    refute inspect(updated.full_name) =~ "Renamed"
    raw = Ash.get!(Op.User, admin.id, authorize?: false)
    refute inspect(raw.full_name) =~ "Renamed"
  end
end
