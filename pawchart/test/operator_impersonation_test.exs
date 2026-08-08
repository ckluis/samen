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
end
