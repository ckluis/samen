defmodule Samen.Web.OperatorImpersonationGateTest do
  @moduledoc """
  T150 — the per-tenant operator drill-in now REQUIRES a real, audited
  `Samen.Impersonation` session (deny-on-read), and provides the missing
  open-session-with-reason affordance so the access lands in the tenant's ledger.

  Proofs (non-vacuous — each pairs the deny with the positive control):

    1. DENIED WITHOUT SESSION — a per-tenant drill-in with an operator identity but NO
       active session renders the access-denied panel + the open-session affordance, with
       NO tenant detail and NO PII.
    2. RENDERS + RECORDS WITH SESSION — after `Samen.Impersonation.open/3` with a reason,
       the SAME drill-in renders masked (`••••`) AND a real `imp_impersonation_session` row
       exists for that org AND the tenant ledger (`Samen.Impersonation.list_for_org/2`) shows
       who / why / expiry.
    3. THE OPEN AFFORDANCE — `handle_event("open_session", %{"reason" => …})` opens a real
       session (the F2 human path — nothing else called `open/3`) and the drill-in re-renders.
    4. PLATFORM VIEWS ARE NOT GATED — the operator's OWN book of business
       (`PlatformBillingLive`) renders WITHOUT any impersonation session (proving the gate was
       scoped to per-tenant drill-ins, not the SaaS's own cross-tenant aggregates).
    5. EXPIRY / CLOSE RE-DENIES — a closed (or expired) session re-masks/denies on the next
       request, honoring the kernel's per-request deny-on-read on the web path.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Delivery.{EmailEvent, Suppression}
  alias Samen.Impersonation
  alias Samen.Web.Operator.DeliverabilityLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds
  alias Samen.WebTest.Repo

  import Ecto.Query, only: [from: 2]

  @recipient_first "Imaginata"
  @recipient_last "Gatetest"
  @recipient_email "imaginata.gate.sentinel@example.test"

  # A tenant org + a recipient User + one bounce event + one suppression (the drill-in's data).
  defp seed_tenant do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "T150 Gate Tenant", plan: "growth"}, authorize?: false)
      |> Ash.create!()

    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org.id,
          handle: "gate-recipient",
          status: "active",
          full_name: %Samen.Type.FullName{first: @recipient_first, last: @recipient_last},
          emails: [%{label: "work", address: @recipient_email}]
        },
        authorize?: false
      )
      |> Ash.create!()

    {:ok, _suppression} =
      Suppression.suppress(Repo, %{org_id: org.id, subscriber_id: user.id, reason: "bounce"})

    {:ok, :inserted, _event} =
      EmailEvent.record(Repo, %{
        provider: "gatetest",
        provider_event_id: "evt_gate_#{System.unique_integer([:positive])}",
        kind: "bounce",
        send_id: Ash.UUID.generate(),
        org_id: org.id,
        subscriber_id: user.id,
        occurred_at: DateTime.utc_now()
      })

    org
  end

  defp drill_in_socket(operator_id) do
    mount = build_operator_mount(Ecto.UUID.generate())

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> with_operator_identity(operator_id)
  end

  defp render(socket), do: render_html(DeliverabilityLive, socket.assigns)

  # ==========================================================================
  # 1. DENIED WITHOUT SESSION (deny-on-read) + the open affordance is offered
  # ==========================================================================

  test "a per-tenant drill-in is DENIED with no active session — no detail, no PII, offers the open-session form" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()

    socket = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)

    assert socket.assigns.impersonation == :denied
    assert is_nil(socket.assigns.detail)

    html = render(socket)
    assert html =~ "no active impersonation session"
    # The F2 open-session affordance is offered (reason-required).
    assert html =~ "open-session-form"
    assert html =~ ~s(phx-submit="open_session")
    # No tenant data / PII leaked on the deny state.
    refute html =~ @recipient_email
    refute html =~ "suppression-row"
  end

  # ==========================================================================
  # 2. RENDERS + RECORDS WITH SESSION — real row + tenant ledger who/why/expiry
  # ==========================================================================

  test "after open/3 with a reason: the drill-in renders MASKED, a real imp row exists, and the tenant ledger shows who/why/expiry" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()
    reason = "ticket #4242: bounce investigation"

    {:ok, session} = Impersonation.open(%Samen.OperatorPlane.Actor{id: operator_id, operator_role: :operator_support}, org.id, reason)

    socket = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)
    assert socket.assigns.impersonation == :active
    refute is_nil(socket.assigns.detail)

    html = render(socket)
    # The drill-in renders the tenant's REAL data, masked by construction (operator plane, no grant).
    assert html =~ "suppression-row"
    assert html =~ "••••"
    refute html =~ @recipient_email
    # The accountability line names the session (who/why/expiry).
    assert html =~ "session-accountability"
    assert html =~ reason

    # A REAL imp_impersonation_session row exists for this org (not a synthetic marker).
    assert Repo.exists?(from(s in "imp_impersonation_session", where: s.imp_org_id == ^Ecto.UUID.dump!(org.id)))

    # The tenant-visible ledger shows who / why / expiry (the honesty gap SecurityLive promised).
    ledger = Impersonation.list_for_org(org.id)
    entry = Enum.find(ledger, &(&1.session_id == session.id))
    assert entry.operator_id == operator_id
    assert entry.reason == reason
    assert entry.active?
    assert %DateTime{} = entry.expires_at
  end

  # ==========================================================================
  # 3. THE OPEN AFFORDANCE — handle_event("open_session", …) calls open/3 (F2)
  # ==========================================================================

  test "the open-session form (handle_event/3) opens a real session with the operator's reason, then the drill-in renders" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()

    denied = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)
    assert denied.assigns.impersonation == :denied

    {:noreply, opened} =
      DeliverabilityLive.handle_event("open_session", %{"reason" => "ticket #7781: dispatch dispute"}, denied)

    assert opened.assigns.impersonation == :active
    assert render(opened) =~ "••••"

    # The reason the operator typed is now in the tenant ledger.
    ledger = Impersonation.list_for_org(org.id)
    assert Enum.any?(ledger, &(&1.operator_id == operator_id and &1.reason == "ticket #7781: dispatch dispute" and &1.active?))
  end

  test "the open-session form refuses a blank reason (reason-required, fail closed)" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()

    denied = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)
    {:noreply, still} = DeliverabilityLive.handle_event("open_session", %{"reason" => "   "}, denied)

    assert still.assigns.open_error =~ "reason"
    assert Impersonation.list_for_org(org.id) == []
  end

  # ==========================================================================
  # 4. PLATFORM VIEWS ARE NOT GATED (correct scoping — the SaaS's own book)
  # ==========================================================================

  test "PLATFORM view (platform billing) renders WITHOUT any impersonation session — it is NOT a per-tenant drill-in" do
    seed = OpSeeds.seed_all(tenants: 2)
    mount = build_operator_mount(seed.operator_org_id)

    # No session opened anywhere. The operator's OWN cross-tenant book of business renders.
    html = render_live(Samen.Web.Operator.PlatformBillingLive, mount, [])

    assert html =~ "subscription-row"
    assert html =~ OpSeeds.admin_full_name()
    refute html =~ "no active impersonation session"
  end

  # ==========================================================================
  # 5. EXPIRY / CLOSE RE-DENIES — per-request deny-on-read on the web path
  # ==========================================================================

  test "a CLOSED session re-denies + re-masks on the next drill-in request (per-request deny-on-read)" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()

    {:ok, session} = Impersonation.open(%Samen.OperatorPlane.Actor{id: operator_id, operator_role: :operator_admin}, org.id, "ticket #1: look")

    active = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)
    assert active.assigns.impersonation == :active

    {:ok, _closed} = Impersonation.close(session.id)

    redenied = drill_in_socket(operator_id) |> DeliverabilityLive.load(org.id)
    assert redenied.assigns.impersonation == :denied
    assert is_nil(redenied.assigns.detail)
    refute render(redenied) =~ @recipient_email
  end

  test "an EXPIRED session denies mid-flight — the gate checks expiry per request, not per open" do
    org = seed_tenant()
    operator_id = Ecto.UUID.generate()

    # A session that is already past its window (deny-on-read against the row, no worker needed).
    {:ok, _session} =
      Impersonation.open(%Samen.OperatorPlane.Actor{id: operator_id, operator_role: :operator_admin}, org.id, "ticket #2: brief", window_minutes: 1)

    # Ask the kernel with a clock past expiry — the gate's underlying scope denies.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert {:error, :session_inactive} = Samen.Impersonation.scope(operator_id, org.id, now: future)
    # And the positive control: at now, it is active.
    assert {:ok, _} = Samen.Impersonation.scope(operator_id, org.id)
  end
end
