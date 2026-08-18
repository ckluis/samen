defmodule PawChart.OperatorImpersonationTest do
  @moduledoc """
  T157 — the per-tenant DRILL-IN with an impersonation SESSION (T150/T153/T154), pawchart shape.

  Drives the SAME load path `PawChartWeb.OperatorImpersonationLive` uses:

    * BEFORE a session is opened, the scope is `{:error, :session_inactive}` — deny-on-read, no data
      (the console renders the access-denied state);
    * `Samen.Web.Operator.Impersonation.open/4` opens a REASON-REQUIRED, accountability-ledgered
      session (the T150 seam) — gated by the operator role;
    * with the session live, the masked patient roster reads REAL clinic data with the owner's
      vault-routed name/emails/phones `%Masked{}` (••••) — the operator plane stays masked without a
      reveal grant. The session is visible in the tenant's impersonation ledger (who/why/active);
    * POSITIVE CONTROL (anti-tautology): the TENANT plane over its OWN org reads the owner in CLEAR,
      so the masking above is the operator-plane seam firing, not a blanket refusal to decrypt.
  """
  use PawChart.DataCase, async: false

  alias PawChartWeb.OperatorImpersonationLive, as: Console

  @operator "op-pawchart-platform"
  @role :operator_support
  @clinic_org "c1112d00-0000-4000-8000-0000000000d7"

  defp create_owner do
    PawChart.Clinic.Patient
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @clinic_org,
        full_name: %{first: "Olivia", last: "Owner"},
        emails: ["olivia@example.com"],
        phones: ["+15550001111"]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  test "deny-on-read: BEFORE opening a session, the scope is inactive (no data)" do
    assert {:error, :session_inactive} = Samen.Impersonation.scope(@operator, @clinic_org)
  end

  test "session-gated masked drill-in: owner PII renders •••• under the live impersonation scope" do
    _owner = create_owner()

    # T150 — open a reason-required, ledgered session (gated by the operator role).
    assert {:ok, _session} =
             Samen.Web.Operator.Impersonation.open(@operator, @role, @clinic_org, "ticket #42: billing question")

    {:ok, scope} = Samen.Impersonation.scope(@operator, @clinic_org)
    [patient] = Console.patient_roster(scope)

    # Masked (••••), NEVER plaintext — the operator plane stays masked with no reveal grant.
    assert match?(%Samen.Masked{}, patient.full_name)
    assert match?(%Samen.Masked{}, patient.emails)
    assert match?(%Samen.Masked{}, patient.phones)
    refute inspect(patient.full_name) =~ "Olivia"
    refute inspect(patient.emails) =~ "olivia@example.com"

    # T150/T153 — the session is recorded in the clinic's impersonation ledger (accountability).
    ledger = Samen.Impersonation.list_for_org(@clinic_org)
    entry = Enum.find(ledger, &(&1.operator_id == @operator and &1.active?))
    assert entry
    assert entry.reason == "ticket #42: billing question"
  end

  test "POSITIVE CONTROL (non-vacuous): the TENANT plane over its OWN org reads the owner CLEAR" do
    _owner = create_owner()

    tenant_actor = %{plane: :tenant, org_id: @clinic_org, role: :member}

    [resolved] =
      PawChart.Clinic.Patient
      |> Ash.Query.ensure_selected([:full_name, :emails, :phones])
      |> Ash.read!(authorize?: false)
      |> Samen.Api.PiiResolution.resolve(PawChart.Clinic.Patient, tenant_actor, repo: PawChart.Repo)

    assert inspect(resolved.full_name) =~ "Olivia"
    refute match?(%Samen.Masked{}, resolved.full_name)
  end

  # ---------------------------------------------------------------------------
  # H2/M1 (phase-6 SEC dogfood) — the acting operator is the AUTHENTICATED PRINCIPAL.
  #
  # The console used to derive its acting identity from `Map.get(params, key) ||
  # Map.get(session, key)` — params BEAT the session — and never consulted the
  # `:samen_operator_id` derived from the signed session. `?operator_id=<victim>` therefore
  # booked the tenant's audit-ledger entry under the WRONG operator (attribution forgery) and
  # rendered another operator's active session's roster (session riding).
  # ---------------------------------------------------------------------------
  describe "H2 — a forged ?operator_id is IGNORED; the ledger names the authenticated principal" do
    @principal "op-pawchart-authenticated"
    @victim "op-pawchart-victim"

    defp signed_session(principal), do: %{Samen.Web.Auth.session_user_key() => principal}

    defp mount_console(params, session) do
      {:ok, socket} = Console.mount(params, session, %Phoenix.LiveView.Socket{})
      socket
    end

    test "the acting id resolves from the SIGNED session principal, never the ?operator_id param" do
      socket =
        mount_console(
          %{"operator_id" => @victim, "org_id" => @clinic_org},
          signed_session(@principal)
        )

      assert socket.assigns[:samen_operator_id] == @principal
      assert socket.assigns[:operator_id] == @principal
      refute socket.assigns[:operator_id] == @victim
    end

    test "ledger ATTRIBUTION: opening a session from a forged-param mount books the PRINCIPAL, not the forged id" do
      reason = "ticket #4242: attribution probe"

      socket =
        %{"operator_id" => @victim, "org_id" => @clinic_org}
        |> mount_console(signed_session(@principal))
        |> Phoenix.Component.assign(:samen_operator_role, @role)

      {:noreply, opened} = Console.handle_event("open_session", %{"reason" => reason}, socket)

      # The open succeeded and the console now renders the masked roster (positive control:
      # this is a REAL session, not a silently-swallowed no-op).
      refute opened.assigns.session_inactive
      assert opened.assigns.impersonating

      ledger = Samen.Impersonation.list_for_org(@clinic_org)

      # POSITIVE CONTROL — the CORRECT id landed in the tenant's accountability ledger.
      assert Enum.any?(ledger, &(&1.operator_id == @principal and &1.reason == reason and &1.active?)),
             "expected the authenticated principal to be named in the tenant ledger"

      # THE PROOF — the forged id is nowhere in the ledger.
      refute Enum.any?(ledger, &(&1.operator_id == @victim)),
             "the client-supplied ?operator_id must NEVER reach the tenant's audit ledger"
    end

    test "SESSION RIDING: a forged ?operator_id cannot borrow another operator's live session" do
      _owner = create_owner()

      # The victim holds a REAL, active session over this clinic...
      assert {:ok, _} =
               Samen.Web.Operator.Impersonation.open(@victim, @role, @clinic_org, "ticket #7: victim's own work")

      # ...and the attacker mounts with the victim's id in the URL, authenticated as themselves.
      socket =
        mount_console(
          %{"operator_id" => @victim, "org_id" => @clinic_org},
          signed_session(@principal)
        )

      assert socket.assigns.session_inactive, "riding the victim's session must be DENIED"
      assert socket.assigns.patients == []
      refute socket.assigns.impersonating

      # POSITIVE CONTROL (anti-tautology): with a session of their OWN, the same mount admits —
      # so the denial above is the identity resolution firing, not a blanket refusal.
      assert {:ok, _} =
               Samen.Web.Operator.Impersonation.open(@principal, @role, @clinic_org, "ticket #8: my own work")

      admitted =
        mount_console(
          %{"operator_id" => @victim, "org_id" => @clinic_org},
          signed_session(@principal)
        )

      assert admitted.assigns.impersonating
      refute admitted.assigns.session_inactive
      assert length(admitted.assigns.patients) == 1
    end

    test "NO-SESSION mount is DENIED — no principal, no params, no data" do
      _owner = create_owner()

      # Even with somebody else's live session in play, a mount carrying no identity at all
      # resolves to nil and fails closed (never crashes — `load/3`'s nil guard).
      assert {:ok, _} =
               Samen.Web.Operator.Impersonation.open(@victim, @role, @clinic_org, "ticket #9: victim's own work")

      socket = mount_console(%{"org_id" => @clinic_org}, %{})

      assert socket.assigns.session_inactive
      assert socket.assigns.patients == []
      assert socket.assigns.session_info == nil
    end
  end
end
