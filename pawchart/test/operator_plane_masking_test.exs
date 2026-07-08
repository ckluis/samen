defmodule PawChart.OperatorPlaneMaskingTest do
  @moduledoc """
  RED-PATH test: the human OWNER's PII is MASKED on the operator plane. When an operator
  reads a Patient (the owner) cross-tenant — via an operator API-key actor OR a masked
  impersonation session — the vault-routed name/emails/phones are NEVER plaintext:

    * an OPERATOR API-KEY actor (no grant) → the field is ABSENT (`%Ash.ForbiddenField{}`,
      omitted by the serializer) — the doc's "a vaulted field is absent unless a reveal
      grant covers it";
    * an IMPERSONATION session (no grant) → the field renders `%Masked{}` (`••••`),
      present-but-masked — the doc's "personal data renders •••• by default".

  Both paths are pure substrate (`Samen.Api.PiiResolution` + `Samen.Impersonation`) with
  ZERO PawChart operator-plane code. The positive control (anti-tautology) proves the
  guarantee is non-vacuous: the TENANT plane over its OWN org reads the same owner in
  CLEAR — so the masking is the operator seam firing, not a blanket refusal to decrypt.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  alias Samen.Api.PiiResolution

  @org "00000000-0000-0000-0000-0000000000e1"

  # The exact actor map `Samen.Impersonation.Scope.build/1` produces from an active
  # session: operator plane + the `:impersonation` marker, NO reveal grant. PawChart is
  # a thin slice with no operator-plane suspension table wired, so we assert the masking
  # POSTURE the impersonation scope carries (present-but-•••• under the operator plane)
  # directly via the substrate resolver — the same code path a live session drives.
  defp impersonation_actor(org) do
    %{
      id: "op-pawchart-mask",
      org_id: org,
      role: :member,
      plane: :operator,
      impersonation: %{operator_id: "op-pawchart-mask", org_id: org, session_id: "sess-1"}
    }
  end

  defp create_owner do
    PawChart.Clinic.Patient
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        full_name: %{first: "Olivia", last: "Owner"},
        emails: ["olivia@example.com"],
        phones: ["+15550001111"]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp read_owner(id) do
    PawChart.Clinic.Patient
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones])
    |> Ash.read_one!(authorize?: false)
  end

  test "operator API-KEY actor (no grant) → owner PII is ABSENT (ForbiddenField), never plaintext" do
    owner = create_owner()
    record = read_owner(owner.id)

    operator_actor = %{plane: :operator, org_id: nil, role: :operator_support}

    [resolved] =
      PiiResolution.resolve([record], PawChart.Clinic.Patient, operator_actor, repo: PawChart.Repo)

    # ABSENT (the serializer omits %Ash.ForbiddenField{}), never plaintext.
    assert match?(%Ash.ForbiddenField{}, resolved.full_name)
    assert match?(%Ash.ForbiddenField{}, resolved.emails)
    assert match?(%Ash.ForbiddenField{}, resolved.phones)
    refute inspect(resolved) =~ "Olivia"
    refute inspect(resolved) =~ "olivia@example.com"
  end

  test "impersonation posture (no grant) → owner PII renders •••• (%Masked{}), never plaintext" do
    owner = create_owner()
    record = read_owner(owner.id)

    [impersonated] =
      PiiResolution.resolve(
        [record],
        PawChart.Clinic.Patient,
        impersonation_actor(@org),
        repo: PawChart.Repo
      )

    # Present-but-masked (•••• via %Masked{}) under impersonation — NOT absent, never
    # plaintext (the doc's "personal data renders •••• by default" for the operator UI).
    assert match?(%Samen.Masked{}, impersonated.full_name)
    assert match?(%Samen.Masked{}, impersonated.emails)
    assert match?(%Samen.Masked{}, impersonated.phones)
    refute to_string(impersonated.full_name) =~ "Olivia"
    refute inspect(impersonated) =~ "olivia@example.com"
  end

  test "POSITIVE CONTROL (non-vacuous): the TENANT plane over its OWN org reads the owner in CLEAR" do
    owner = create_owner()
    record = read_owner(owner.id)

    # A tenant key over its OWN org reads its own customers' PII in clear (no grant) —
    # proving the operator masking above is the seam firing, not an always-mask tautology.
    tenant_actor = %{plane: :tenant, org_id: @org, role: :member}

    [resolved] =
      PiiResolution.resolve([record], PawChart.Clinic.Patient, tenant_actor, repo: PawChart.Repo)

    # Composite FullName decrypts to a struct/map carrying the cleartext name.
    assert inspect(resolved.full_name) =~ "Olivia"
    refute match?(%Samen.Masked{}, resolved.full_name)
    refute match?(%Ash.ForbiddenField{}, resolved.full_name)
  end
end
