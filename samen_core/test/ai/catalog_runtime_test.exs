defmodule Samen.AI.CatalogRuntimeTest do
  @moduledoc """
  T66 — the D9 catalog served at runtime as the grounding source (ADR-043 §8).

  Proves:

    * RP-AI-8 — the runtime catalog (`Samen.AI.Catalog.dict/1` / `schema/1`) is IDENTICAL to
      `mix samen.catalog.dump`'s `build_dict/1` output for the same resources (normalized diff
      empty). This holds BY CONSTRUCTION (the Mix task delegates to `Samen.AI.Catalog.dict/1`
      — `samen.catalog.dump.ex`), but the parity test still asserts it as the CONTRACT: a
      future edit that forks the two paths is caught immediately, not by prose.
    * Plane-aware serving (§8, INV-1 probe): every field carries a boolean `pii` flag; NO
      sample/row VALUE ever appears anywhere in the catalog shape (bounded key set).
    * Kernel consumption (T66 done-criteria #3): `Samen.AI.complete/4` auto-populates
      `:grounding` from this catalog — the sealed payload's grounding is CATALOG-DERIVED
      (changes when the resource does), not a hand-written string.
    * Org isolation (the hard invariant — "grounding must never cross orgs"): the static
      schema half is org-INVARIANT (same for every org, so there is no per-org row to leak —
      the §6.4 token-blind-by-schema argument); the org-VARIANT custom-object half
      (`Samen.CustomObjects`) is genuinely org-scoped — org A's grounding never contains org
      B's custom-object catalog, modeled on `custom_objects_test.exs`'s
      "no cross-org leak in the catalog" red path.
  """
  use ExUnit.Case, async: false

  alias Samen.AI
  alias Samen.AI.{Catalog, MaskedPayload, Provider}
  alias Samen.CustomObjects
  alias SamenCore.TestRepo

  @fixture_resources [
    SamenCore.Support.Crm.Contact,
    SamenCore.Support.Crm.Company,
    SamenCore.Support.Clinical.Patient
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Provider.Fake.reset()
    :ok
  end

  # --------------------------------------------------------------------------------------
  # RP-AI-8 — runtime catalog == mix samen.catalog.dump (normalized diff empty)

  describe "RP-AI-8 — parity with mix samen.catalog.dump" do
    test "Samen.AI.Catalog.dict/1 is identical to Mix.Tasks.Samen.Catalog.Dump.build_dict/1" do
      runtime = Catalog.dict(@fixture_resources)
      dump = Mix.Tasks.Samen.Catalog.Dump.build_dict(@fixture_resources)

      assert runtime == dump,
             "the D9 runtime catalog must be byte-for-byte identical to mix samen.catalog.dump"

      # Anti-tautology: non-trivial on both sides.
      assert length(runtime["tables"]) == 3
    end

    test "parity holds through JSON round-tripping too (the artifact format itself)" do
      runtime_json = @fixture_resources |> Catalog.dict() |> Jason.encode!(pretty: true)
      dump_json = @fixture_resources |> Mix.Tasks.Samen.Catalog.Dump.build_dict() |> Jason.encode!(pretty: true)

      assert runtime_json == dump_json
    end

    test "schema/1 with an explicit :resources override matches dict/1 on the same list" do
      assert Catalog.schema(resources: @fixture_resources) == Catalog.dict(@fixture_resources)
    end
  end

  # --------------------------------------------------------------------------------------
  # Plane-aware serving: pii metadata present, NO sample values ever (§8, INV-1 probe)

  describe "plane-aware serving — pii flag as metadata, never a sample value" do
    test "every field carries a boolean pii flag, keyed on the vault DECLARATION" do
      dict = Catalog.dict([SamenCore.Support.Clinical.Patient])
      [table] = dict["tables"]

      by_col = Map.new(table["fields"], fn f -> {f["column_name"], f["pii"]} end)

      assert by_col["pat_full_name"] == true
      assert by_col["pat_emails"] == true
      assert by_col["pii_pat_dob"] == true
      assert by_col["pat_id"] == false

      # Anti-vacuity: both true and false appear.
      flags = Enum.map(table["fields"], & &1["pii"])
      assert Enum.any?(flags, &(&1 == true))
      assert Enum.any?(flags, &(&1 == false))
    end

    test "the catalog shape carries NO sample/row value — only bounded metadata keys" do
      dict = Catalog.dict(@fixture_resources)
      all_fields = Enum.flat_map(dict["tables"], & &1["fields"])
      assert all_fields != []

      allowed_keys = MapSet.new(["column_name", "logical_name", "type", "pii"])

      for field <- all_fields do
        keys = field |> Map.keys() |> MapSet.new()

        assert MapSet.subset?(keys, allowed_keys),
               "field entry carries an unexpected key (possible sample-value leak): #{inspect(field)}"

        refute Map.has_key?(field, "sample")
        refute Map.has_key?(field, "value")
      end
    end
  end

  # --------------------------------------------------------------------------------------
  # T66-F4 fix-round (delta-verifier finding): a malformed resources/domains argument
  # degrades gracefully rather than raising — dict/1 and schema/1 lacked the rescue
  # custom_objects/2 and grounding/2 already had.

  describe "fail-safe degradation on a malformed resources/domains argument (T66-F4)" do
    test "dict/1 skips a non-Ash-resource ENTRY (Enum) rather than raising, keeping the rest" do
      assert Catalog.dict([Enum]) == %{"tables" => []}

      # The good entries survive alongside the bad one — a partial degrade, not an all-or-
      # nothing wipe.
      mixed = Catalog.dict([SamenCore.Support.Crm.Company, Enum, nil, "not a module"])
      assert mixed == Catalog.dict([SamenCore.Support.Crm.Company])
      assert mixed["tables"] != []
    end

    test "schema/1 degrades to an empty table list on a malformed :resources entry" do
      assert Catalog.schema(resources: [Enum]) == %{"tables" => []}
    end

    test "schema/1 degrades to an empty table list when :domains cannot be resolved" do
      assert Catalog.schema(domains: [Enum, :not_a_domain, "nope"]) == %{"tables" => []}
    end

    test "grounding/2 stays fail-safe end-to-end with a malformed :resources override" do
      assert Catalog.grounding(:scope, resources: [Enum]) == %{schema: %{"tables" => []}, custom_objects: []}
    end
  end

  # --------------------------------------------------------------------------------------
  # Kernel consumption (T66 done-criteria #3): AI.complete/4 auto-populates :grounding from
  # the catalog — proving prompt context is catalog-DERIVED, not a hand-written string.

  describe "kernel consumption — Samen.AI.complete/4 auto-populates :grounding" do
    test "the sealed payload's grounding contains catalog-derived table/field names" do
      assert {:ok, %AI.Completion{}} =
               AI.complete(:scope, "hi", %{}, domains: [SamenCore.Support.Crm])

      assert [{:complete, %MaskedPayload{grounding: grounding}}] = Provider.Fake.sent_payloads()

      table_names = grounding.schema["tables"] |> Enum.map(& &1["table_name"])
      assert "com_contact" in table_names
      assert "cpy_company" in table_names

      # It is DERIVED, not hand-written: the exact fixture introspection agrees byte-for-byte.
      assert grounding.schema == Catalog.dict(Samen.Catalog.resource_modules(SamenCore.Support.Crm))
    end

    test "an explicit :grounding opt overrides the auto-populated catalog (caller wins)" do
      assert {:ok, %AI.Completion{}} =
               AI.complete(:scope, "hi", %{}, grounding: %{hand_written: true})

      assert [{:complete, %MaskedPayload{grounding: %{hand_written: true}}}] =
               Provider.Fake.sent_payloads()
    end

    test "grounding auto-population never blocks a completion when :domains is unset" do
      # With no `:domains`/`:resources` opt, auto-grounding falls back to the host's
      # registered `config :samen_core, :ash_domains` (samen_core's own kernel fixtures, in
      # this app's case) — the call must still seal (never raise/block), and the result
      # matches calling the catalog directly with the same (default) inputs.
      assert {:ok, %AI.Completion{}} = AI.complete(:scope, "hi", %{})
      assert [{:complete, %MaskedPayload{grounding: grounding}}] = Provider.Fake.sent_payloads()
      assert grounding.schema == Catalog.schema()
      assert grounding.schema["tables"] != [], "the default host domains are non-trivial here"
    end
  end

  # --------------------------------------------------------------------------------------
  # Org isolation — the hard invariant: "grounding must never cross orgs"

  describe "org isolation — one org cannot ground on another org's catalog" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
      :ok
    end

    defp org, do: Ash.UUID.generate()

    test "the static schema half is org-INVARIANT (no row to leak — same for every org)" do
      a = Catalog.schema(resources: @fixture_resources)
      b = Catalog.schema(resources: @fixture_resources)

      # Two independent calls (standing in for two different orgs' actors) get the IDENTICAL
      # schema — there is no per-org branch in this half at all, so there is nothing an org
      # could leak into another org's context (§6.4's "no column to leak" argument, applied
      # to the schema catalog instead of the analytics aggregate).
      assert a == b
      refute Map.has_key?(a, :org_id)
    end

    test "the org-scoped custom-object half never leaks org A's catalog into org B's grounding" do
      org_a = org()
      org_b = org()

      {:ok, _} =
        CustomObjects.define_object(%{org_id: org_a, object_key: "only_a", label: "Only A"}, TestRepo)

      {:ok, _} =
        CustomObjects.define_object_field(
          %{org_id: org_a, object_key: "only_a", field_name: "lot_number", type: :string},
          TestRepo
        )

      grounding_a = Catalog.grounding(%{org_id: org_a}, resources: [])
      grounding_b = Catalog.grounding(%{org_id: org_b}, resources: [])

      assert Enum.any?(grounding_a.custom_objects, &(&1.object_key == "only_a"))
      assert grounding_b.custom_objects == []

      # Positive control: the leak scan genuinely fires — org A's object key does NOT appear
      # anywhere in org B's grounding (not just the top-level list check above).
      refute inspect(grounding_b) =~ "only_a"
    end

    test "a disabled custom object is excluded from grounding (not a live source)" do
      org_id = org()

      {:ok, _} =
        CustomObjects.define_object(
          %{org_id: org_id, object_key: "off_object", enabled: false},
          TestRepo
        )

      grounding = Catalog.grounding(%{org_id: org_id}, resources: [])
      refute Enum.any?(grounding.custom_objects, &(&1.object_key == "off_object"))
    end

    test "a scope with no resolvable org_id (e.g. a bare test atom) grounds with NO custom objects" do
      assert Catalog.custom_objects(nil) == []
      assert Catalog.grounding(:scope, resources: []).custom_objects == []
    end
  end
end
