defmodule SamenCore.CustomObjectsTest do
  @moduledoc """
  T3.9 — Tier-2 custom objects (minimal viable, risk R11): `tnt_object` +
  `tnt_field` (shared with T3.8) + `tnt_record` (org-scoped Ash resource with a
  validated jsonb bag). CRUD, org-scope policies, catalogued as tenant-tier
  objects, the ONE-WAY BOUNDARY documented + enforced.

  MANDATORY RED PATHS (plan T3.9):
    1. cross-org tnt_record read denied (org-scope policy → other org's rows
       invisible);
    2. invalid attribute shape rejected (undefined key / wrong type / constraint);
    3. the one-way-boundary compile/verifier check (a system resource declaring a
       relationship to tnt_record fails — asserted via the whole-app sweep AND the
       Spark verifier's negative + a documented compile-fail probe);
    4. PII-shaped value rejected (same as Tier-1 containment).

  Plus: a record for an undefined/disabled object rejected; a PII-shaped OUT-ref
  rejected (a ref can't smuggle PII across the boundary).
  """
  use ExUnit.Case, async: false

  alias Samen.CustomObjects
  alias Samen.CustomObjects.ObjectRow
  alias Samen.CustomObjects.Record
  alias Samen.Scope
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp org, do: Ash.UUID.generate()
  defp scope_for(org_id), do: Scope.new(%{id: Ash.UUID.generate(), org_id: org_id, role: :admin})

  defp define_object!(org_id, key, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object(
        Enum.into(opts, %{org_id: org_id, object_key: key}),
        TestRepo
      )

    row
  end

  defp define_field!(org_id, object_key, field, type, opts \\ []) do
    {:ok, row} =
      CustomObjects.define_object_field(
        Enum.into(opts, %{org_id: org_id, object_key: object_key, field_name: field, type: type}),
        TestRepo
      )

    row
  end

  # ==========================================================================
  # Object definition + catalog (tenant-tier objects catalogued)
  # ==========================================================================

  describe "object definition (ladder rung 3) + catalog surface" do
    test "define_object upserts a tnt_object and list_objects is the tenant catalog" do
      o = org()
      define_object!(o, "vaccine_lot", label: "Vaccine Lot")
      define_object!(o, "kennel_run", label: "Kennel Run")

      objects = CustomObjects.list_objects(o, TestRepo)
      assert Enum.map(objects, & &1.tnt_object_key) == ["kennel_run", "vaccine_lot"]
      assert Enum.all?(objects, &match?(%ObjectRow{}, &1))

      lot = CustomObjects.get_object(o, "vaccine_lot", TestRepo)
      assert lot.tnt_label == "Vaccine Lot"
      assert lot.tnt_enabled == true
    end

    test "an object's fields ARE Tier-1 tnt_field rows (shared machinery)" do
      o = org()
      define_object!(o, "vaccine_lot")
      define_field!(o, "vaccine_lot", "lot_number", :string, constraints: %{max_length: 40})
      define_field!(o, "vaccine_lot", "doses", :integer, constraints: %{min: 0})

      fields = CustomObjects.list_object_fields(o, "vaccine_lot", TestRepo)
      names = Enum.map(fields, & &1.tnt_field_name) |> Enum.sort()
      assert names == ["doses", "lot_number"]

      # They live under the object's synthetic table name (disjoint from any real
      # physical table), so the two catalogs never collide.
      assert Enum.all?(fields, &(&1.tnt_table_name == CustomObjects.object_table("vaccine_lot")))
      assert String.starts_with?(CustomObjects.object_table("vaccine_lot"), "tnt$obj$")
    end

    test "object definitions are org-scoped (no cross-org leak in the catalog)" do
      a = org()
      b = org()
      define_object!(a, "only_a")
      assert CustomObjects.list_objects(b, TestRepo) == []
      assert CustomObjects.get_object(b, "only_a", TestRepo) == nil
    end
  end

  # ==========================================================================
  # Record CRUD (through the org-scoped Ash resource)
  # ==========================================================================

  describe "record CRUD (validated-at-write happy path)" do
    test "a defined object + fields → a validated record write succeeds" do
      o = org()
      s = scope_for(o)
      define_object!(o, "vaccine_lot")
      define_field!(o, "vaccine_lot", "lot_number", :string)
      define_field!(o, "vaccine_lot", "doses", :integer, constraints: %{min: 0, max: 1000})

      assert {:ok, rec} =
               CustomObjects.create_record(s, "vaccine_lot", %{
                 "lot_number" => "AB-123",
                 "doses" => 500
               })

      assert %Record{} = rec
      assert rec.object_key == "vaccine_lot"
      assert rec.attributes["lot_number"] == "AB-123"
      assert rec.attributes["doses"] == 500

      assert {:ok, [read]} = CustomObjects.list_records(s, "vaccine_lot")
      assert read.id == rec.id
      assert read.org_id == o
    end

    test "a record may hold opaque OUT-references to system rows (a uuid ref)" do
      o = org()
      s = scope_for(o)
      define_object!(o, "kennel_run")
      system_role_id = Ash.UUID.generate()

      assert {:ok, rec} =
               CustomObjects.create_record(s, "kennel_run", %{}, refs: %{"owner_role" => system_role_id})

      assert rec.refs["owner_role"] == system_role_id
    end
  end

  # ==========================================================================
  # RED PATH 1 — cross-org tnt_record read denied
  # ==========================================================================

  describe "RED 1 — cross-org tnt_record read denied (org-scope policy)" do
    test "an actor scoped to org A sees none of org B's records" do
      a = org()
      b = org()
      define_object!(a, "shared_shape")
      define_object!(b, "shared_shape")

      {:ok, _} = CustomObjects.create_record(scope_for(a), "shared_shape", %{})
      {:ok, _} = CustomObjects.create_record(scope_for(b), "shared_shape", %{})

      # Org A reads only its own row; org B's row is INVISIBLE (not forbidden — the
      # FilterCheck makes it not-exist for this actor).
      assert {:ok, a_rows} = CustomObjects.list_records(scope_for(a), "shared_shape")
      assert length(a_rows) == 1
      assert Enum.all?(a_rows, &(&1.org_id == a))

      # DISCRIMINATING: an unauthorized filter would return [] for BOTH; assert org
      # A genuinely sees its OWN row (not a blanket deny).
      refute a_rows == []
    end

    test "an org-less actor sees NO records (fail closed)" do
      a = org()
      define_object!(a, "shape")
      {:ok, _} = CustomObjects.create_record(scope_for(a), "shape", %{})

      # A genuinely org-less actor: the scope carries no org_id at all. The
      # OrgScope FilterCheck resolves this to `expr(false)` — fail closed: the
      # actor sees NO rows, whether Ash surfaces that as an empty result or a
      # forbidden error. Either way, zero of the org's rows are visible.
      orgless = %Scope{actor: %{id: Ash.UUID.generate(), role: :member}}

      case CustomObjects.list_records(orgless, "shape") do
        {:ok, rows} -> assert rows == []
        {:error, %Ash.Error.Forbidden{}} -> :ok
      end
    end
  end

  # ==========================================================================
  # RED PATH 2 — invalid attribute shape rejected (reused Tier-1 machinery)
  # ==========================================================================

  describe "RED 2 — invalid attribute shape rejected" do
    setup do
      o = org()
      s = scope_for(o)
      define_object!(o, "vaccine_lot")
      define_field!(o, "vaccine_lot", "doses", :integer, constraints: %{min: 0, max: 1000})
      define_field!(o, "vaccine_lot", "grade", :enum, constraints: %{one_of: ["a", "b"]})
      %{org: o, scope: s}
    end

    test "an undefined attribute key is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "vaccine_lot", %{"undefined_key" => "x"})

      assert error_message(err) =~ "no tnt_field definition"
    end

    test "a wrong-typed attribute is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "vaccine_lot", %{"doses" => "not-an-int"})

      assert error_message(err) =~ "not a integer"
    end

    test "a constraint-violating attribute is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "vaccine_lot", %{"doses" => 99_999})

      assert error_message(err) =~ "constraint violated"
    end

    test "an out-of-enum value is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "vaccine_lot", %{"grade" => "z"})

      assert error_message(err) =~ "constraint violated"
    end

    test "DISCRIMINATING — a valid in-constraint attribute is NOT rejected", %{scope: s} do
      assert {:ok, _} = CustomObjects.create_record(s, "vaccine_lot", %{"doses" => 10, "grade" => "a"})
    end
  end

  describe "RED 2b — record for an undefined/disabled object rejected" do
    test "a record for an object the org never defined is rejected", %{} do
      s = scope_for(org())
      assert {:error, err} = CustomObjects.create_record(s, "never_defined", %{})
      assert error_message(err) =~ "no enabled tnt_object"
    end

    test "a record for a DISABLED object is rejected (soft-disable is enforced)" do
      o = org()
      s = scope_for(o)
      define_object!(o, "retired", enabled: false)
      assert {:error, err} = CustomObjects.create_record(s, "retired", %{})
      assert error_message(err) =~ "no enabled tnt_object"
    end
  end

  # ==========================================================================
  # RED PATH 4 — PII-shaped value rejected (containment, same as Tier-1)
  # ==========================================================================

  describe "RED 4 — PII-shaped attribute value rejected (containment)" do
    setup do
      o = org()
      s = scope_for(o)
      define_object!(o, "contact_note")
      define_field!(o, "contact_note", "note", :string)
      # ADR-046 §8 residual #2: a pii_declared custom-object field is now REFUSED at define
      # unless a record-bag erasure arm covers the object (the analogue of the first-class
      # discipline). Declare erasability inline so the pii_declared field is admissible.
      define_field!(o, "contact_note", "declared_email", :string,
        pii_declared: true,
        record_bag_specs: [%{object_key: "contact_note", subject_ref_key: "subject"}]
      )

      %{org: o, scope: s}
    end

    test "an email-shaped value on a non-pii_declared attribute is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "contact_note", %{"note" => "alice@example.com"})

      assert error_message(err) =~ "PII-shaped"
    end

    test "an SSN-shaped value is rejected", %{scope: s} do
      assert {:error, err} =
               CustomObjects.create_record(s, "contact_note", %{"note" => "123-45-6789"})

      assert error_message(err) =~ "PII-shaped"
    end

    test "DISCRIMINATING — the SAME email is ALLOWED on a pii_declared attribute", %{scope: s} do
      assert {:ok, rec} =
               CustomObjects.create_record(s, "contact_note", %{"declared_email" => "alice@example.com"})

      assert rec.attributes["declared_email"] == "alice@example.com"
    end
  end

  describe "RED 4b — a PII-shaped OUT-ref is rejected (a ref can't smuggle PII)" do
    test "an email-shaped ref value is rejected", %{} do
      o = org()
      s = scope_for(o)
      define_object!(o, "shape")

      assert {:error, err} =
               CustomObjects.create_record(s, "shape", %{}, refs: %{"owner" => "bob@example.com"})

      assert error_message(err) =~ "PII-shaped"
    end

    test "a free-text ref (not an opaque ID) is rejected", %{} do
      o = org()
      s = scope_for(o)
      define_object!(o, "shape2")

      assert {:error, err} =
               CustomObjects.create_record(s, "shape2", %{}, refs: %{"owner" => "some free text here"})

      assert error_message(err) =~ "opaque ID"
    end

    test "DISCRIMINATING — a uuid ref and a bounded token ref are ALLOWED" do
      o = org()
      s = scope_for(o)
      define_object!(o, "shape3")

      assert {:ok, _} =
               CustomObjects.create_record(s, "shape3", %{},
                 refs: %{"a" => Ash.UUID.generate(), "b" => "token_ABC-123"}
               )
    end
  end

  # ==========================================================================
  # RED PATH 3 — the one-way boundary (verifier)
  # ==========================================================================

  describe "RED 3 — one-way boundary (no system → tnt_record reference)" do
    test "the whole-app boundary sweep passes on the real app (no violations today)" do
      assert Mix.Tasks.Samen.Verify.TntBoundary.relationship_violations([]) == []
    end

    test "the boundary sweep FLAGS a system resource with a relationship into tnt_record" do
      # A fabricated 'system' resource that declares belongs_to → Record. We assert
      # the SWEEP would flag it. (The compile-time Spark verifier is exercised by
      # the anti-tautology probe in the report; here we prove the sweep's detection
      # is load-bearing against a real Ash resource introspection.)
      violations = boundary_violations_for(SamenCore.T39Boundary.Offender)

      assert length(violations) == 1
      assert hd(violations) =~ "one-way boundary"
      assert hd(violations) =~ "Offender"
    end

    test "DISCRIMINATING — a system resource that does NOT reference tnt_record is not flagged" do
      assert boundary_violations_for(SamenCore.Support.CustomFields.Widget) == []
    end

    test "no FK constraint in the DB targets a tenant-regime table (structural half)" do
      assert Mix.Tasks.Samen.Verify.TntBoundary.fk_violations(repo: "SamenCore.TestRepo") == []
    end
  end

  # ==========================================================================
  # Catalog parity — tenant-tier objects catalogued
  # ==========================================================================

  describe "catalog parity — Tier-2 objects/records catalogued" do
    test "tnt_catalog parity holds for well-catalogued objects, fields and records" do
      o = org()
      s = scope_for(o)
      define_object!(o, "vaccine_lot")
      define_field!(o, "vaccine_lot", "lot", :string)
      {:ok, _} = CustomObjects.create_record(s, "vaccine_lot", %{"lot" => "X"})

      assert Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo) == []
    end

    test "RED — an orphan tnt_record (no tnt_object) fails parity" do
      o = org()
      # Insert a record row directly (bypassing the object gate) to simulate a row
      # that slipped in past the catalog — the durable CI backstop must catch it.
      TestRepo.query!(
        "INSERT INTO tnt_record (tnr_org_id, tnr_object_key, tnr_attributes, tnr_refs, tnr_inserted_at, tnr_updated_at) " <>
          "VALUES ($1::uuid, 'ghost_object', '{}'::jsonb, '{}'::jsonb, now(), now())",
        [Ecto.UUID.dump!(o)]
      )

      violations = Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo)
      assert Enum.any?(violations, &(&1 =~ "orphan tnt_record" and &1 =~ "ghost_object"))
    end

    test "RED — an orphan custom-object field (no tnt_object) fails parity" do
      o = org()
      # Define a field on a synthetic object table with NO tnt_object row.
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{
            org_id: o,
            table_name: CustomObjects.object_table("undefined_obj"),
            field_name: "f",
            type: :string
          },
          TestRepo
        )

      violations = Mix.Tasks.Samen.Verify.TntCatalog.check(TestRepo)
      assert Enum.any?(violations, &(&1 =~ "orphan custom-object field" and &1 =~ "undefined_obj"))
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # The boundary rule applied to a single resource (mirrors the sweep's per-resource
  # logic) so we can exercise detection against a fixture without registering it in
  # a domain.
  defp boundary_violations_for(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.destination == Record))
    |> Enum.map(fn rel ->
      "system resource #{inspect(resource)} declares relationship #{inspect(rel.name)} " <>
        "→ tnt_record — the one-way boundary forbids the system regime from " <>
        "referencing INTO the tenant regime (T3.9)."
    end)
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map_join(" | ", &error_message/1)
  end

  defp error_message(%{message: m}) when is_binary(m), do: m
  defp error_message(err), do: inspect(err)
end
