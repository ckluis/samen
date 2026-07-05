defmodule Samen.PiiInfoTest do
  @moduledoc """
  T1.3 (d) + the introspection API the T1.4/T1.5 vault runtime and the C3/C5
  verifiers consume (`Samen.Pii.Info`).

  Proves the contract the plan states T1.4/T1.5 need: for each resource, the list
  of vault-routed attributes, their vaults, and their STORAGE names — and that
  `vault_routed?/2` keys on the DECLARATION, not on the `pii_` prefix (a composite
  field like `pat_full_name` has no prefix but IS vault-routed).
  """
  use ExUnit.Case, async: true

  alias Samen.Pii.Info
  alias SamenCore.Support.Clinical.Patient

  # Patient folds Core.Person (full_name/emails/phones composites) and adds its own
  # scalar dob/mrn — a resource exercising BOTH storage-naming rules.

  test "pii_attributes/1 lists every declared field (composite + scalar, folded + own)" do
    names = Patient |> Info.pii_attributes() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == [:dob, :emails, :full_name, :mrn, :phones]
  end

  test "vaults/1 lists every declared vault (folded + own)" do
    assert Enum.sort(Info.vaults(Patient)) ==
             [:pii_dob, :pii_email, :pii_mrn, :pii_name, :pii_phone]
  end

  test "fields/1 resolves storage names per the routing rule (composite vs scalar)" do
    by_name = Patient |> Info.fields() |> Map.new(&{&1.name, &1})

    # Composite fields route by vault name: abbrev prefix, NO pii_ prefix.
    assert by_name[:full_name].storage_name == :pat_full_name
    assert by_name[:full_name].composite? == true
    assert by_name[:emails].storage_name == :pat_emails
    assert by_name[:phones].storage_name == :pat_phones

    # Scalar pii_attributes carry the pii_ prefix.
    assert by_name[:dob].storage_name == :pii_pat_dob
    assert by_name[:dob].composite? == false
    assert by_name[:mrn].storage_name == :pii_pat_mrn
    assert by_name[:mrn].composite? == false
  end

  test "fields/1 carries the declared type and vault for each field" do
    by_name = Patient |> Info.fields() |> Map.new(&{&1.name, &1})
    assert by_name[:full_name].type == Samen.Type.FullName
    assert by_name[:full_name].vault == :pii_name
    assert by_name[:dob].type == :date
    assert by_name[:dob].vault == :pii_dob
  end

  test "routing/1 maps vault => storage columns — the T1.4 vault routing table" do
    routing = Info.routing(Patient)
    assert routing[:pii_name] == [:pat_full_name]
    assert routing[:pii_email] == [:pat_emails]
    assert routing[:pii_dob] == [:pii_pat_dob]
    assert routing[:pii_mrn] == [:pii_pat_mrn]
  end

  test "vault_routed?/2 keys on the DECLARATION, not the pii_ prefix" do
    # Composite: storage name has NO pii_ prefix, yet it IS vault-routed.
    assert Info.vault_routed?(Patient, :full_name)
    assert Info.vault_routed?(Patient, :emails)
    # Scalar: prefixed AND routed.
    assert Info.vault_routed?(Patient, :dob)
    # A non-PII plain column is NOT vault-routed.
    refute Info.vault_routed?(Patient, :consent_on_file)
    refute Info.vault_routed?(Patient, :org_id)
  end

  test "vault_routed_columns/1 is the physical column set the oracle scans" do
    cols = Patient |> Info.vault_routed_columns() |> Enum.sort()

    assert cols ==
             [:pat_emails, :pat_full_name, :pat_phones, :pii_pat_dob, :pii_pat_mrn]

    # It is exactly the union of the routing table's storage names.
    routed = Info.routing(Patient) |> Map.values() |> List.flatten() |> Enum.sort()
    assert cols == routed
  end

  test "the composite storage names carry NO pii_ prefix but ARE in the routed set" do
    cols = Info.vault_routed_columns(Patient)
    # This is the load-bearing invariant: downstream verifiers must NOT rely on a
    # pii_ prefix to find vault-routed data. per_full_name / pat_full_name is proof.
    assert :pat_full_name in cols
    refute to_string(:pat_full_name) =~ ~r/^pii_/
  end
end
