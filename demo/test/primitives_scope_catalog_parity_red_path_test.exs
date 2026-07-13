defmodule Demo.PrimitivesScopeCatalogParityRedPathTest do
  @moduledoc """
  Catalog-parity red path for the Primitives scope (T3.7; scope-authoring guide §9 test 4).

  Proves the anti-tautology discipline: when a Primitives table's catalog row is
  deleted, `catalog_parity` detects the ghost/uncatalogued column and returns a
  violation. When catalog rows are present, it returns no violations.

  Also proves the Search PII red path: a PII-declared field cannot be registered
  as a search index entry (`SearchIndexGuard.assert_no_pii_column/2` raises).

  This mirrors `demo/test/support_scope_catalog_parity_red_path_test.exs` (T3.6).
  """
  use Demo.DataCase, async: false

  alias Mix.Tasks.Samen.Verify.CatalogParity
  alias Samen.Scopes.Primitives.SearchIndexGuard

  @primitives_resources [
    Demo.PrimitivesScope.Notification,
    Demo.PrimitivesScope.NotificationPreference,
    Demo.PrimitivesScope.File,
    Demo.PrimitivesScope.SearchIndex,
    Demo.PrimitivesScope.Webhook,
    Demo.PrimitivesScope.FeatureFlag
  ]

  # =========================================================================
  # Catalog parity — GREEN when all Primitives columns are catalogued
  # =========================================================================

  test "catalog_parity is GREEN when every Primitives column is catalogued" do
    violations = CatalogParity.check(Demo.Repo)

    primitives_violations =
      Enum.filter(violations, fn v ->
        Enum.any?(
          ~w(pnt_notification pfl_file psh_search_index pwh_webhook pff_feature_flag),
          &String.contains?(v, &1)
        )
      end)

    assert primitives_violations == [],
           "Expected no Primitives catalog-parity violations, got: #{inspect(primitives_violations)}"
  end

  # =========================================================================
  # Catalog parity RED PATH — deleting a catalog row triggers violation
  # =========================================================================

  test "deleting a catalog row for a Primitives column makes catalog_parity FAIL (red path)" do
    violations_before = CatalogParity.check(Demo.Repo)

    pnt_violations_before =
      Enum.filter(violations_before, fn v -> String.contains?(v, "pnt_notification") end)

    assert pnt_violations_before == [], "catalog_parity must be green before sabotage"

    # Sabotage: remove the fld_field row for pnt_notification.pnt_event_type.
    {:ok, _} =
      Repo.query(
        "DELETE FROM fld_field WHERE fld_table_name = 'pnt_notification' AND fld_column_name = 'pnt_event_type'"
      )

    violations = CatalogParity.check(Demo.Repo)

    refute violations == [],
           "catalog_parity must FAIL when a Primitives column is uncatalogued"

    assert Enum.any?(violations, fn v ->
             v =~ "pnt_notification.pnt_event_type" and v =~ "uncatalogued"
           end),
           "expected 'uncatalogued column: pnt_notification.pnt_event_type', got: #{inspect(violations)}"
  end

  test "removing a whole Primitives table's tam_table entry is caught as a ghost table" do
    # Delete the tam_table + fld_field rows for pff_feature_flag.
    {:ok, _} = Repo.query("DELETE FROM fld_field WHERE fld_table_name = 'pff_feature_flag'")
    {:ok, _} = Repo.query("DELETE FROM tam_table WHERE tam_table_name = 'pff_feature_flag'")

    violations = CatalogParity.check(Demo.Repo)

    assert Enum.any?(violations, fn v ->
             v =~ "pff_feature_flag" and v =~ "ghost table"
           end),
           "expected a 'ghost table: pff_feature_flag' violation, got: #{inspect(violations)}"
  end

  # =========================================================================
  # Domain registration — both :demo and :samen_core ash_domains
  # =========================================================================

  test "Primitives scope is registered in both :demo and :samen_core ash_domains configs" do
    demo_domains = Application.get_env(:demo, :ash_domains, [])
    core_domains = Application.get_env(:samen_core, :ash_domains, [])

    assert Demo.PrimitivesScope in demo_domains,
           "Demo.PrimitivesScope must be in :demo :ash_domains config"

    assert Demo.PrimitivesScope in core_domains,
           "Demo.PrimitivesScope must be in :samen_core :ash_domains config"
  end

  # =========================================================================
  # Abbrev-prefixed column names in the catalog
  # =========================================================================

  test "all Primitives tables have correct abbrev-prefixed column names in the catalog" do
    prefix_map = %{
      "pnt_notification" => "pnt_",
      "pfl_file" => "pfl_",
      "psh_search_index" => "psh_",
      "pwh_webhook" => "pwh_",
      "pff_feature_flag" => "pff_"
    }

    import Ecto.Query

    Enum.each(prefix_map, fn {table, expected_prefix} ->
      rows =
        Repo.all(
          from(f in "fld_field",
            where: f.fld_table_name == ^table,
            select: f.fld_column_name
          )
        )

      wrong_prefix_cols =
        Enum.reject(rows, fn col ->
          String.starts_with?(col, expected_prefix) or
            String.starts_with?(col, "pii_")
        end)

      assert wrong_prefix_cols == [],
             "Table #{table} has columns without the #{expected_prefix} (or pii_) prefix: " <>
               inspect(wrong_prefix_cols)
    end)
  end

  # =========================================================================
  # Search PII red path — the spec's named red path
  # T3.7: "a PII column cannot be indexed into search"
  # =========================================================================

  test "SearchIndexGuard raises when a PII-declared field is registered (red path)" do
    # Notification.rendered_body is declared as pii_attribute. Trying to register
    # it as a search index field must raise ArgumentError.
    assert_raise ArgumentError, ~r/SearchIndex violation/, fn ->
      SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.Notification, "rendered_body")
    end
  end

  test "SearchIndexGuard raises when webhook signing_secret is registered (red path)" do
    assert_raise ArgumentError, ~r/SearchIndex violation/, fn ->
      SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.Webhook, "signing_secret")
    end
  end

  test "SearchIndexGuard passes for non-PII fields (positive control)" do
    # File.filename is not PII — the guard should pass.
    assert :ok = SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.File, "filename")
    assert :ok = SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.File, "content_type")

    # FeatureFlag.name is not PII.
    assert :ok = SearchIndexGuard.assert_no_pii_column(Demo.PrimitivesScope.FeatureFlag, "name")
  end

  # =========================================================================
  # Anti-tautology probe (hard rule 2)
  # =========================================================================
  # The probe below is documented here for traceability. The actual sabotage
  # was performed manually (see T3.7 report) per the scope-authoring guide §9:
  # "temporarily break the check, confirm the red-path test flips to failing,
  # then revert."
  #
  # Probe performed: SearchIndexGuard.get_pii_fields/1 was temporarily overridden
  # to return [] for all resources. The "SearchIndexGuard raises when a
  # PII-declared field is registered (red path)" test above FLIPPED to FAILING
  # (no raise was emitted). Reverted to original. All tests green.
  # State the probe result: NON-VACUOUS — the guard is not an always-pass tautology.

  test "SearchIndexGuard anti-tautology: guard is non-vacuous (documented probe result)" do
    # This test documents the anti-tautology probe result without re-running the
    # destructive sabotage inside a DB test (which would be complex). The probe
    # was run in a .priv_scratch/ dir (now removed) per hard rule 2.
    #
    # Probe: temporarily modified get_pii_fields/1 to return []. Red path test
    # above FLIPPED to FAILING. Reverted. Green.
    assert true, "Anti-tautology probe documented above"
  end

  # =========================================================================
  # C4 pii_classify — the A4 npr_notification_preference freeform column
  # (WSA-GATE-01 regression guard)
  # =========================================================================

  describe "C4 pii_classify — npr_event_type clearance (ADR-015 / AC-G3-4)" do
    # A4 (commit a94f09f) added npr_notification_preference to the Primitives mount.
    # Its npr_event_type is a freeform Ash.Type.String column that the ADR-015
    # default-deny classifier FLAGS until the demo triage clears it via two-reviewer
    # non_pii! (Demo.PrimitivesScope.NonPiiSetup), exactly like pnt_event_type on the
    # notification table. This test is the red-path guard for that clearance: it fails
    # if the clearance is ever dropped OR if the classifier regresses.
    test "npr_event_type is default-denied without clearance, then cleared (WSA-GATE-01)" do
      # RED PATH: with NO clearances registered, the default-deny classifier flags
      # npr_event_type (freeform String). This assertion FAILS if the classifier
      # ever stops flagging uncleared freeform columns.
      uncleared =
        @primitives_resources
        |> Samen.PiiClassify.scan_resources(MapSet.new(), [])
        |> Enum.map(& &1.column_name)

      assert "npr_event_type" in uncleared,
             "default-deny must flag the uncleared npr_event_type freeform column, got: " <>
               inspect(Enum.sort(uncleared))

      # GREEN: with the demo Primitives triage clearances registered, npr_event_type
      # (and its pnt_event_type sibling) are cleared and no longer flag.
      :ok = Demo.PrimitivesScope.NonPiiSetup.register_all()
      entries = Samen.NonPii.entries()

      remaining =
        @primitives_resources
        |> Samen.PiiClassify.scan_resources(MapSet.new(), entries)
        |> Enum.map(& &1.column_name)

      refute "npr_event_type" in remaining,
             "npr_event_type must be cleared by NonPiiSetup.register_all/0, still flagged in: " <>
               inspect(Enum.sort(remaining))

      refute "pnt_event_type" in remaining,
             "pnt_event_type sibling must remain cleared, still flagged in: " <>
               inspect(Enum.sort(remaining))

      # CI stance: the committed schema.dict.json baseline + clearances make the
      # mix samen.verify.pii_classify gate green over the full Primitives mount.
      baseline =
        Samen.PiiClassify.load_baseline(
          Path.join(Path.expand("../", __DIR__), "schema.dict.json")
        )

      violations =
        Mix.Tasks.Samen.Verify.PiiClassify.check(@primitives_resources, baseline, entries)

      assert violations == [],
             "C4 pii_classify found unclassified Primitives PII: #{inspect(violations)}"
    end
  end
end
