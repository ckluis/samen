defmodule Samen.Web.OperatorScopeGateTest do
  @moduledoc """
  T84 — the R-B account-scope conjunct on the per-tenant drill-in door (ADR-044 §16.4a,
  RP-J-16) and the real `scope_of/2` reader over the assignment resource (ruling R-A).

  `may_drill_in? := T146 role AND (org_id ∈ scope_of/2) AND T150 session` — three
  ADDITIVE conjuncts. This suite proves the SCOPE conjunct at the product's drill-in
  gate (`Samen.Web.Operator.Impersonation.gate/3`), enumerating the drill-in LiveViews
  rather than hand-listing one:

    * RED — a scoped-OUT operator (valid role, account NOT in `{:accounts, …}`) is denied
      at the door, BEFORE the reason form (`:out_of_scope`, never `:denied`) — opening a
      session must never be a way to discover you lack scope;
    * positive control :all — an admin (`:all`) is unaffected on EVERY drill-in;
    * positive control in-scope — an in-scope operator gets the T150 reason form, and
      after a session, the masked drill-in;
    * scope is NOT a substitute for T150 — an in-scope operator with no session still
      sees the reason form (`:denied`), never rows;
    * NO-LOCKOUT / fleet-independent — with NO `:fleet_resolution` seam configured, every
      drill-in behaves exactly as before (refuting the "separately-deployed fleet locks
      everyone out" composition error);
    * the real `scope_from_assignments/4` reader shapes (`:all` / `{:accounts, set}` /
      `:none`) + fail-closed;
    * the minimal admin surface is `:operator_admin`-gated (OperatorAdminOnly).

  `async: false` — wires `:fleet_resolution` into `:samen_web`'s app env per test and
  resets it in `on_exit`, so no other suite sees a configured seam (they stay inert).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Fleet.{Assignments, Resolution}
  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Operator.{ActivityLive, AutomationHealthLive, DeliverabilityLive}
  alias Samen.Web.Operator.Impersonation, as: Gate
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.OperatorScope.Assignment

  @resolver {Samen.WebTest.OperatorScope.Resolver, :scope, [:samen_web]}
  @admin Actor.new("admin-provisioner", :operator_admin)

  # The three per-tenant drill-in LiveViews that compose the R-B scope gate. Kept as a
  # single list the enumerated assertions iterate — a fourth drill-in added later is
  # covered the day it joins this list (the RP-J-12/16 enumeration discipline).
  @drill_ins [DeliverabilityLive, ActivityLive, AutomationHealthLive]

  defp seed_org(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name, plan: "growth"}, authorize?: false)
    |> Ash.create!()
  end

  defp wire_resolution! do
    Application.put_env(:samen_web, :fleet_resolution, @resolver)
    on_exit(fn -> Application.delete_env(:samen_web, :fleet_resolution) end)
  end

  defp set_role(operator_id, role) do
    roles = Application.get_env(:samen_web, :test_operator_roles, %{})
    Application.put_env(:samen_web, :test_operator_roles, Map.put(roles, operator_id, role))
    on_exit(fn -> Application.delete_env(:samen_web, :test_operator_roles) end)
  end

  # A drill-in socket for `operator_id`, mounted on the samen_web test host (otp_app
  # :samen_web via the WebTest repo), so `gate/3` reads the wired :fleet_resolution seam.
  defp drill_in_socket(operator_id, role) do
    mount = build_operator_mount(Ecto.UUID.generate())

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> with_operator_identity(operator_id, role)
  end

  # Load a drill-in LiveView (each has its own load arity) and return the resulting socket.
  defp load(DeliverabilityLive, socket, org_id), do: DeliverabilityLive.load(socket, org_id)
  defp load(ActivityLive, socket, org_id), do: ActivityLive.load(socket, org_id, 24)
  defp load(AutomationHealthLive, socket, org_id), do: AutomationHealthLive.load(socket, org_id)

  # ==========================================================================
  # scope_from_assignments/4 — the real reader (ruling R-A)
  # ==========================================================================

  describe "scope_from_assignments/4 (the real reader over the assignment resource)" do
    test ":all for a broad role — no row needed (parity with /operator/accounts)" do
      for role <- [:operator_admin, :operator_support, :operator_break_glass] do
        assert :all == Resolution.scope_from_assignments(Assignment, role, :samen_web, Ecto.UUID.generate())
      end
    end

    test "{:accounts, set} for an assignable role WITH rows; :none WITHOUT" do
      operator_id = Ecto.UUID.generate()
      a = seed_org("Scope A")
      b = seed_org("Scope B")

      # Fail-closed by absence BEFORE any grant.
      assert :none == Resolution.scope_from_assignments(Assignment, :operator_readonly, :samen_web, operator_id)

      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, a.id, @admin)
      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, b.id, @admin)

      assert {:accounts, set} =
               Resolution.scope_from_assignments(Assignment, :operator_readonly, :samen_web, operator_id)

      assert MapSet.equal?(set, MapSet.new([a.id, b.id]))
    end

    test "grants are scoped to the (operator, app_scope) pair — a foreign operator's rows do not leak" do
      me = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      mine = seed_org("Mine")
      theirs = seed_org("Theirs")

      {:ok, _} = Assignments.grant(Assignment, me, :samen_web, mine.id, @admin)
      {:ok, _} = Assignments.grant(Assignment, other, :samen_web, theirs.id, @admin)

      assert {:accounts, set} =
               Resolution.scope_from_assignments(Assignment, :operator_readonly, :samen_web, me)

      assert MapSet.equal?(set, MapSet.new([mine.id]))
      refute MapSet.member?(set, theirs.id)
    end

    test "a nil principal and a bad resource fail CLOSED to :none" do
      assert :none == Resolution.scope_from_assignments(Assignment, :operator_readonly, :samen_web, nil)
      assert :none == Resolution.scope_from_assignments(Not.A.Real.Resource, :operator_readonly, :samen_web, "x")
    end
  end

  # ==========================================================================
  # The minimal admin surface is :operator_admin-gated (OperatorAdminOnly)
  # ==========================================================================

  describe "the assignment admin surface (ruling R-A — gated :operator_admin)" do
    test "a non-admin operator may NOT grant or list" do
      support = Actor.new("s", :operator_support)
      readonly = Actor.new("r", :operator_readonly)
      org = seed_org("Admin Gate")

      assert {:error, _} = Assignments.grant(Assignment, Ecto.UUID.generate(), :samen_web, org.id, support)
      assert {:error, _} = Assignments.grant(Assignment, Ecto.UUID.generate(), :samen_web, org.id, readonly)
      assert {:error, _} = Assignments.list(Assignment, Ecto.UUID.generate(), :samen_web, support)
      # A non-operator (tenant) actor is refused too.
      assert {:error, _} = Assignments.grant(Assignment, Ecto.UUID.generate(), :samen_web, org.id, %{plane: :tenant})
    end

    test "an operator-admin may grant (idempotent) and revoke" do
      operator_id = Ecto.UUID.generate()
      org = seed_org("Admin OK")

      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, org.id, @admin)
      # Idempotent re-grant (upsert on the unique identity) — not a duplicate.
      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, org.id, @admin)
      {:ok, rows} = Assignments.list(Assignment, operator_id, :samen_web, @admin)
      assert length(rows) == 1

      :ok = Assignments.revoke(Assignment, operator_id, :samen_web, org.id, @admin)
      assert :none == Resolution.scope_from_assignments(Assignment, :operator_readonly, :samen_web, operator_id)
    end
  end

  # ==========================================================================
  # gate/3 — the R-B scope conjunct at the drill-in door (RP-J-16)
  # ==========================================================================

  describe "gate/3 scope conjunct — RED: scoped-out is denied at the door, before the reason form" do
    setup do
      wire_resolution!()
      :ok
    end

    test "a scoped-OUT operator (valid role, account not in scope) is :out_of_scope on EVERY drill-in" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_readonly)
      in_scope = seed_org("In Scope")
      out_scope = seed_org("Out Of Scope")
      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, in_scope.id, @admin)

      # Direct gate/3: the out-of-scope org is denied BEFORE any session consideration.
      assert :out_of_scope == Gate.gate(operator_id, out_scope.id, :samen_web)

      # Enumerated across the drill-in LiveViews: :out_of_scope state, NO reason form, no rows.
      for view <- @drill_ins do
        socket = load(view, drill_in_socket(operator_id, :operator_readonly), out_scope.id)
        assert socket.assigns.impersonation == :out_of_scope,
               "#{inspect(view)} must deny an out-of-scope account with :out_of_scope"

        html = render_html(view, socket.assigns)
        assert html =~ "not in your scope"
        refute html =~ "open-session-form"
        refute html =~ ~s(phx-submit="open_session")
      end
    end

    test "even with an ACTIVE session, a scoped-out account stays :out_of_scope (scope subtracts, never adds)" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_readonly)
      out_scope = seed_org("Out w/ session")
      # A session exists but the account is not in scope — the scope conjunct still denies.
      {:ok, _} = Impersonation.open(Actor.new(operator_id, :operator_support), out_scope.id, "ticket #1")

      assert :out_of_scope == Gate.gate(operator_id, out_scope.id, :samen_web)
    end

    test "a scoped-out open is REFUSED even on a crafted submit — no session row is minted" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_readonly)
      out_scope = seed_org("Out craft")

      socket = load(DeliverabilityLive, drill_in_socket(operator_id, :operator_readonly), out_scope.id)
      {:noreply, after_open} =
        DeliverabilityLive.handle_event("open_session", %{"reason" => "ticket #9: sneak"}, socket)

      assert after_open.assigns.impersonation == :out_of_scope
      assert Impersonation.list_for_org(out_scope.id) == []
    end
  end

  describe "gate/3 scope conjunct — positive controls" do
    setup do
      wire_resolution!()
      :ok
    end

    test ":all (admin) is UNAFFECTED on every drill-in — in scope everywhere" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_admin)
      org = seed_org("Admin Sees All")

      # No assignment row at all, yet admin is in scope (never :out_of_scope) — it lands on
      # the ordinary T150 deny (no session) → the reason form, exactly like before.
      assert :denied == Gate.gate(operator_id, org.id, :samen_web)

      for view <- @drill_ins do
        socket = load(view, drill_in_socket(operator_id, :operator_admin), org.id)
        assert socket.assigns.impersonation == :denied
        refute socket.assigns.impersonation == :out_of_scope
      end
    end

    test "in-scope operator: no session ⇒ reason form (:denied), scope is NOT a substitute for T150" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_readonly)
      org = seed_org("In scope no session")
      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, org.id, @admin)

      assert :denied == Gate.gate(operator_id, org.id, :samen_web)

      socket = load(DeliverabilityLive, drill_in_socket(operator_id, :operator_readonly), org.id)
      assert socket.assigns.impersonation == :denied
      html = render_html(DeliverabilityLive, socket.assigns)
      assert html =~ "open-session-form"
      refute html =~ "not in your scope"
    end

    test "in-scope operator WITH a session ⇒ the masked drill-in renders" do
      operator_id = Ecto.UUID.generate()
      set_role(operator_id, :operator_support)
      org = seed_org("In scope w/ session")
      {:ok, _} = Assignments.grant(Assignment, operator_id, :samen_web, org.id, @admin)
      {:ok, _} = Impersonation.open(Actor.new(operator_id, :operator_support), org.id, "ticket #2: look")

      assert {:ok, _actor, _info} = Gate.gate(operator_id, org.id, :samen_web)
    end
  end

  # ==========================================================================
  # NO-LOCKOUT — the gate is fleet-independent (§16.4a, refutes the composition error)
  # ==========================================================================

  describe "no-lockout — the R-B gate is fleet-independent" do
    test "with NO :fleet_resolution seam configured, every drill-in behaves as before (a drill-in PASSES)" do
      # Deliberately DO NOT wire_resolution!() — this is the "no fleet configured at all" case.
      refute Resolution.configured?(:samen_web)

      operator_id = Ecto.UUID.generate()
      org = seed_org("No fleet")
      {:ok, _} = Impersonation.open(Actor.new(operator_id, :operator_admin), org.id, "ticket #3")

      # gate/3 with the product otp_app but no seam → scope inert → the session governs.
      assert {:ok, _actor, _info} = Gate.gate(operator_id, org.id, :samen_web)

      # And a drill-in with no session is a plain :denied (reason form), NEVER :out_of_scope.
      other = seed_org("No fleet no session")
      socket = load(DeliverabilityLive, drill_in_socket(Ecto.UUID.generate(), :operator_readonly), other.id)
      assert socket.assigns.impersonation == :denied
      refute socket.assigns.impersonation == :out_of_scope
    end

    test "gate/2 (legacy, no otp_app) never engages scope — identical to pre-Amendment" do
      operator_id = Ecto.UUID.generate()
      org = seed_org("Legacy gate/2")
      assert :denied == Gate.gate(operator_id, org.id)
      {:ok, _} = Impersonation.open(Actor.new(operator_id, :operator_admin), org.id, "ticket #4")
      assert {:ok, _actor, _info} = Gate.gate(operator_id, org.id)
    end

    test "a wired-but-erroring seam denies (fail-closed → :out_of_scope), the mask-by-omission direction" do
      Application.put_env(:samen_web, :fleet_resolution, {Not.Real, :nope, [:samen_web]})
      on_exit(fn -> Application.delete_env(:samen_web, :fleet_resolution) end)

      org = seed_org("Erroring seam")
      # configured? is true (MFA shape present) but the resolver errors → scope_of :none →
      # out of scope. A wired seam that breaks fails toward LESS access, never more.
      assert :out_of_scope == Gate.gate(Ecto.UUID.generate(), org.id, :samen_web)
    end
  end
end
