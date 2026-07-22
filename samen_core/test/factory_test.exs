defmodule Samen.FactoryTest do
  @moduledoc """
  `Samen.Factory` (WS-D D1.2; ADR-022) — AC-G4-5: the factory writes PII through
  the SAME Ash create actions as `Samen.Web.SampleData` (byte-identical vault
  path), proven on the real `Clinical.Patient` fixture (composite `full_name`/
  `emails`/`phones` from the `Core.Person` fragment + scalar `mrn`/`dob`).

  GREEN — a `Factory.create!` and a `SampleData`-idiom create (the literal
  `Ash.Changeset.for_create(:create, attrs, scope: scope)` pipeline from
  `samen_web/lib/samen/web/sample_data.ex`) produce the SAME at-rest token
  shape: `vt_*` tokens in every vaulted domain column, one `pii_vault`
  ciphertext row per vaulted field, no plaintext anywhere in the raw row
  (the A5 raw-SQL proof pattern).

  RED — a factory write that would land plaintext PII in a physical column is
  impossible/refused:

    * attrs keyed by a vault-routed field's PHYSICAL storage column
      (`pii_pat_mrn`, `pat_full_name`) raise `ArgumentError` by name, DB
      untouched (the factory's own belt);
    * an operator-plane `%Samen.Scope{}` writing plaintext PII is refused by
      `Samen.Pii.WriteGuard` (MC-1 / Invariant L1) — the factory adds no
      privilege over the guarded write path — DB unchanged.

  Anti-tautology: the green controls prove the factory is not a stub (rows land,
  tokens are real, ciphertext exists); the red paths prove the guarantees are
  not vacuous (both refusals leave provably zero rows).
  """
  use ExUnit.Case, async: false

  alias Samen.Factory
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  # Tenant-plane scope mirroring Samen.Web.Plane.scope/2 for kind: :tenant —
  # the scope SampleData threads via `scope: Mount.scope(mount, org_id)`.
  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "broker:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  # Operator-plane scope mirroring Samen.Web.Plane.scope/2 for kind: :operator.
  defp operator_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "operator:op-1",
        org_id: org_id,
        role: :member,
        kind: :operator,
        plane: :operator,
        impersonation: %{session_id: "op-session"}
      }
    }
  end

  defp pii_attrs(org_id) do
    Map.merge(
      %{org_id: org_id, mrn: "MRN-FCT-SECRET-9", dob: ~D[1912-06-23]},
      Factory.person("Ada", "Lovelace",
        email: "ada.lovelace@sample.invalid",
        phone: "+1 555 0199"
      )
    )
  end

  defp raw_row(id) do
    %{rows: [[json]]} =
      @repo.query!("SELECT to_jsonb(t)::text FROM pat_patient t WHERE pat_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    json
  end

  defp vaulted_columns(id) do
    %{rows: [row]} =
      @repo.query!(
        "SELECT pat_full_name, pat_emails, pat_phones, pii_pat_mrn, pii_pat_dob " <>
          "FROM pat_patient WHERE pat_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  defp vault_field_names(id) do
    %{rows: rows} =
      @repo.query!("SELECT field_name FROM pii_vault WHERE subject_id = $1", [id])

    rows |> Enum.map(fn [name] -> name end) |> Enum.sort()
  end

  defp patient_count(org_id) do
    %{rows: [[n]]} =
      @repo.query!("SELECT count(*) FROM pat_patient WHERE pat_org_id = $1", [
        Ecto.UUID.dump!(org_id)
      ])

    n
  end

  # ---------------------------------------------------------------------------
  # GREEN — AC-G4-5: same at-rest token shape as the SampleData idiom
  # ---------------------------------------------------------------------------

  test "Factory.create! and the SampleData-idiom create produce the SAME at-rest token shape" do
    org_id = Ash.UUID.generate()
    scope = tenant_scope(org_id)

    # The factory write.
    factory_rec = Factory.create!(Patient, pii_attrs(org_id), scope)

    # The SampleData idiom, verbatim (sample_data.ex: for_create(:create, attrs,
    # scope: scope) |> Ash.create!()) — the reference the factory must match.
    sample_rec =
      Patient
      |> Ash.Changeset.for_create(:create, pii_attrs(org_id), scope: scope)
      |> Ash.create!()

    for id <- [factory_rec.id, sample_rec.id] do
      # (a) every vaulted domain column holds a vt_* token, never plaintext.
      for col <- vaulted_columns(id) do
        assert is_binary(col)
        assert String.starts_with?(col, "vt_"), "expected vault token, got #{inspect(col)}"
      end

      # (b) one pii_vault ciphertext row per vaulted field — the SAME field set.
      assert vault_field_names(id) == ["dob", "emails", "full_name", "mrn", "phones"]

      # (d) the A5 raw-SQL proof: NO plaintext anywhere in the raw row.
      row = raw_row(id)
      refute row =~ "Ada"
      refute row =~ "Lovelace"
      refute row =~ "ada.lovelace"
      refute row =~ "MRN-FCT-SECRET-9"
      refute row =~ "555 0199"
      # Refute the FULL dob plaintext, not the bare year. ROOT-CAUSE FIX (T102
      # hex-collision flake class): "1912" is all hex and collides by chance with
      # the random vt_<hex> tokens (and UUIDs) that `to_jsonb(t)` embeds in the
      # row, a seed-independent false positive. The full "1912-06-23" carries
      # non-hex separators, so it cannot false-positive while still catching a real
      # plaintext leak of the vaulted dob (~D[1912-06-23]).
      refute row =~ "1912-06-23"
    end
  end

  test "person/3 builds exactly the shipped composite attrs shape (absent keys stay absent)" do
    assert Factory.person("Aster", "Vale") ==
             %{full_name: %Samen.Type.FullName{first: "Aster", last: "Vale"}}

    assert Factory.person("Aster", "Vale",
             email: "aster.vale@sample.invalid",
             phone: "+1 555 0101",
             phone_label: "direct"
           ) == %{
             full_name: %Samen.Type.FullName{first: "Aster", last: "Vale"},
             emails: [%{label: "work", address: "aster.vale@sample.invalid"}],
             phones: [%{label: "direct", number: "+1 555 0101"}]
           }

    # Verbatim entry lists pass through untouched (the Seeds multi-entry idiom).
    assert %{emails: [%{label: "home", address: "a@h.invalid"}]} =
             Factory.person("A", "B", emails: [%{label: "home", address: "a@h.invalid"}])
  end

  test "the keyword-opts arity (the Seeds nil-plane idiom) vault-routes identically" do
    org_id = Ash.UUID.generate()

    rec = Factory.create!(Patient, pii_attrs(org_id), authorize?: false)

    for col <- vaulted_columns(rec.id) do
      assert String.starts_with?(col, "vt_")
    end

    refute raw_row(rec.id) =~ "Lovelace"
  end

  # ---------------------------------------------------------------------------
  # RED — plaintext PII in a physical column is impossible/refused
  # ---------------------------------------------------------------------------

  test "attrs keyed by a PHYSICAL vault column are refused BY NAME, DB untouched" do
    org_id = Ash.UUID.generate()

    # Scalar storage name (pii_ prefix).
    err =
      assert_raise ArgumentError, fn ->
        Factory.create!(
          Patient,
          %{org_id: org_id, pii_pat_mrn: "MRN-RAW-PLAINTEXT"},
          authorize?: false
        )
      end

    assert err.message =~ ":pii_pat_mrn"
    assert err.message =~ ":mrn"
    assert err.message =~ "Samen.Vault.Change"

    # Composite storage name (abbrev prefix, no pii_) — and string keys too.
    assert_raise ArgumentError, ~r/:full_name/, fn ->
      Factory.create!(
        Patient,
        %{"org_id" => org_id, "pat_full_name" => "Raw Plaintext"},
        authorize?: false
      )
    end

    # RED-path teeth: neither refusal wrote anything.
    assert patient_count(org_id) == 0
  end

  test "an operator-plane Factory.create! with plaintext PII is refused by the WriteGuard, DB unchanged" do
    org_id = Ash.UUID.generate()

    err =
      assert_raise Ash.Error.Invalid, fn ->
        Factory.create!(Patient, pii_attrs(org_id), operator_scope(org_id))
      end

    assert Exception.message(err) =~ "no-operator-plaintext-write"

    # RP-L1: the DB is unchanged — no domain row, no vault ciphertext orphans.
    assert patient_count(org_id) == 0
  end
end
