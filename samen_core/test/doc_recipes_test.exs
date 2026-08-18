defmodule Samen.Gen.DocRecipesTest do
  @moduledoc """
  WS-D D9b — claim-evidence parity for `docs/guides/cookbook.md` (AC-G10-3) and
  `docs/guides/gate-failures.md` (AC-G10-4). Both docs cite THIS test by name.

  Cookbook (AC-G10-3):
    * the ≥5 required recipes are present;
    * every backtick-cited repo path in either doc exists on disk;
    * every `mix samen.*` task a recipe names resolves to a real, loadable Mix task;
    * every cited framework macro/function exists — in the cited source file (grep
      evidence, bound BOTH ways: the citation must be in the doc AND the definition
      in the file) and, for samen_core modules, as a loaded module/function.

  Gate-failure index (AC-G10-4):
    * every `samen_core/lib/mix/tasks/samen.verify.*.ex` task has an entry (no
      verifier undocumented — enumerated from the filesystem, not a hardcoded list);
    * every quoted load-bearing error string still exists in the cited verifier
      source — the index cannot drift from what the gate actually prints;
    * the shared `Samen.Verifier.halt_if_violations/2` failure shape is real.

  Fenced `bash` commands in both docs are covered separately by the D9a extractor
  (`test/doc_commands_test.exs`, which includes both docs in its doc set).

  Anti-vacuity: the parity table is checked in BOTH directions (a fragment missing
  from the DOC fails just like one missing from the SOURCE), and a red path proves
  the fragment checker actually fails on a fabricated error string.
  """
  use ExUnit.Case, async: true

  alias Samen.AbbrevRegistry

  @core_root Path.expand("..", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  @cookbook_path Path.join(@repo_root, "docs/guides/cookbook.md")
  @gate_failures_path Path.join(@repo_root, "docs/guides/gate-failures.md")

  defp cookbook, do: File.read!(@cookbook_path)
  defp gate_failures, do: File.read!(@gate_failures_path)
  defp source!(rel), do: File.read!(Path.join(@repo_root, rel))

  # ================================================================ cookbook (AC-G10-3)

  test "AC-G10-3: the cookbook covers the >=5 required recipes" do
    doc = cookbook()
    recipes = Regex.scan(~r/^## Recipe \d+ — .+$/m, doc) |> List.flatten()
    assert length(recipes) >= 5, "cookbook has #{length(recipes)} recipes, need >= 5"

    # The five AC-named topics, each pinned to its recipe heading.
    for topic <- [
          "Add a scope",
          "Bend billing",
          "feature flag",
          "operator cockpit",
          "field on the API"
        ] do
      assert Enum.any?(recipes, &String.contains?(&1, topic)),
             "no recipe heading covers #{inspect(topic)}"
    end
  end

  test "every backtick-cited repo path in cookbook + gate-failures exists on disk" do
    paths =
      for doc <- [cookbook(), gate_failures()],
          [path] <- Regex.scan(~r/`([a-z_]+\/[^`\s]+\.(?:exs?|md|json))`/, doc, capture: :all_but_first),
          uniq: true,
          do: path

    assert length(paths) >= 20, "path extraction looks broken (got #{length(paths)})"

    for path <- paths do
      full = Path.join(@repo_root, path)

      # A citation may be a literal path or a glob (`samen.verify.*.ex`).
      assert File.exists?(full) or Path.wildcard(full) != [],
             "doc cites `#{path}` but it does not exist in the tree"
    end
  end

  test "every `mix samen.*` task the cookbook names resolves to a real Mix task" do
    tasks =
      Regex.scan(~r/mix (samen\.[a-z_.]+)/, cookbook(), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert "samen.gen.scope" in tasks
    assert "samen.gen.resource" in tasks
    assert "samen.verify.api_contract" in tasks

    for task <- tasks do
      assert Mix.Task.get(task), "cookbook names `mix #{task}`, but no such Mix task exists"
    end
  end

  # {citation the cookbook makes, source file, definition that must exist there}.
  @macro_evidence [
    {"samen_operator_routes", "samen_web/lib/samen/web/router.ex",
     "defmacro samen_operator_routes"},
    {"flags_namespace", "samen_web/lib/samen/web/router.ex", "flags_namespace"},
    {"use Samen.Scopes.Billing", "samen_core/lib/samen/scopes/billing.ex",
     "defmacro __using__"},
    {"abbrevs:", "driftwood/lib/driftwood/billing.ex", "abbrevs: %{"},
    {"define_feature_flag", "samen_core/lib/samen/scopes/primitives/blueprint.ex",
     "defmacro define_feature_flag"},
    {"rollout_pct", "samen_core/lib/samen/scopes/primitives/blueprint.ex",
     "attribute(:rollout_pct, :integer"},
    {"Samen.FeatureFlags.evaluate", "samen_core/lib/samen/feature_flags.ex", "def evaluate"},
    {":erlang.phash2({flag_name, subject_key}, 10_000)",
     "samen_core/lib/samen/feature_flags.ex", ":erlang.phash2({flag_name, subject_key}, 10_000)"},
    {"Samen.Web.Operator.FlagAdminLive", "samen_web/lib/samen/web/router.ex",
     "Samen.Web.Operator.FlagAdminLive"},
    {"vault_routing", "samen_core/lib/samen/red_path.ex", "defmacro vault_routing"},
    {"policy_matrix", "samen_core/lib/samen/red_path.ex", "defmacro policy_matrix"},
    {"vault(:pii_microchip)", "pawchart/lib/pawchart/clinic.ex", "vault(:pii_microchip)"},
    {"pii_attribute(:microchip, :string, vault: :pii_microchip)",
     "pawchart/lib/pawchart/clinic.ex",
     "pii_attribute(:microchip, :string, vault: :pii_microchip)"},
    {"reveal(:reveal_pet)", "pawchart/lib/pawchart/clinic.ex", "reveal(:reveal_pet)"},
    {"show_fields", "samen_core/lib/samen/gen/templates.ex", "show_fields"},
    {"derive_filter?", "samen_core/lib/samen/gen/templates.ex", "derive_filter?"},
    {"vault_routing", "samen_core/lib/samen/gen/post_templates.ex", "vault_routing("},
    {"policy_matrix", "samen_core/lib/samen/gen/post_templates.ex", "policy_matrix("}
  ]

  test "every cited macro/function exists in the cited file (bound both ways)" do
    doc = cookbook()

    for {citation, rel_path, definition} <- @macro_evidence do
      assert String.contains?(doc, citation),
             "evidence table drifted: cookbook no longer mentions #{inspect(citation)}"

      src = source!(rel_path)

      assert String.contains?(src, definition),
             "cookbook cites #{inspect(citation)} against #{rel_path}, " <>
               "but #{inspect(definition)} is not there"
    end
  end

  test "cited samen_core modules are real (loaded, with the cited functions)" do
    assert {:module, _} = Code.ensure_loaded(Samen.FeatureFlags)
    assert function_exported?(Samen.FeatureFlags, :evaluate, 3)
    assert %{on: false} = struct(Samen.FeatureFlags.Decision, on: false, reason: :default)
    assert {:module, _} = Code.ensure_loaded(Samen.FeatureFlags.NonPiiTargeting)
    assert {:module, _} = Code.ensure_loaded(Samen.Policy.SameOrgFk)
    assert {:module, _} = Code.ensure_loaded(Samen.Api.PiiResolution)
    assert {:module, _} = Code.ensure_loaded(Samen.Vault.Change)
    assert {:module, _} = Code.ensure_loaded(Samen.Factory)
    assert function_exported?(Samen.Factory, :create!, 3)
    assert {:module, _} = Code.ensure_loaded(Samen.RedPath)
    assert {:module, _} = Code.ensure_loaded(Samen.Scopes.Billing)
  end

  test "recipe example abbrevs are honest: fresh (or example-owned) in the committed registry" do
    registry = AbbrevRegistry.load()

    # Recipe 1's `--abbrev wdg` must be runnable by a reader against the REAL registry.
    for {abbrev, owner_prefix} <- [{"wdg", "Harbor."}] do
      assert Regex.match?(AbbrevRegistry.pattern(), abbrev)

      case Map.get(registry, abbrev) do
        nil -> :ok
        owner -> assert String.starts_with?(owner, owner_prefix),
                        "cookbook example abbrev #{inspect(abbrev)} is owned by #{owner}"
      end
    end
  end

  # ====================================================== gate-failure index (AC-G10-4)

  test "AC-G10-4: every samen.verify.* task has an entry in gate-failures.md" do
    doc = gate_failures()

    task_files =
      Path.wildcard(Path.join(@core_root, "lib/mix/tasks/samen.verify.*.ex"))

    assert length(task_files) >= 17, "verifier enumeration looks broken"

    for file <- task_files do
      task = file |> Path.basename(".ex")

      assert String.contains?(doc, "`mix #{task}`"),
             "verifier #{task} has NO entry in gate-failures.md (AC-G10-4: no verifier undocumented)"
    end

    # The two non-verify gate members the index also documents.
    assert doc =~ "drift check", "the schema.dict.json drift step is undocumented"
    assert doc =~ "anti_tautology_probe.exs", "the anti-tautology probe step is undocumented"
  end

  # {source file, load-bearing fragment}: the fragment must exist VERBATIM in both the
  # doc (the quoted error) and the source (what the gate actually prints).
  @error_evidence [
    # shared failure shape (Samen.Verifier.halt_if_violations/2)
    {"samen_core/lib/samen/verifier.ex", "OK — no violations found."},
    {"samen_core/lib/samen/verifier.ex", ":erlang.halt(1)"},
    # step 1b — emitted ci.sh drift check. The emitter body lives as an externalized raw-text
    # template (priv/templates/ci_sh.eex) read into Samen.Gen.Templates at compile time.
    {"samen_core/priv/templates/ci_sh.eex",
     "FAILED: schema.dict.json is stale — run 'mix samen.catalog.dump --output schema.dict.json' and commit."},
    # catalog_parity
    {"samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex", "uncatalogued column: "},
    {"samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex", "orphan fld_field row: "},
    {"samen_core/lib/mix/tasks/samen.verify.catalog_parity.ex", "not in tam_table)"},
    # prefixes
    {"samen_core/lib/mix/tasks/samen.verify.prefixes.ex", "unprefixed column: "},
    {"samen_core/lib/mix/tasks/samen.verify.prefixes.ex", "unprefixed fld_field row: "},
    {"samen_core/lib/mix/tasks/samen.verify.prefixes.ex", "[expected prefix: "},
    # pii_reads
    {"samen_core/lib/samen/pii_reads/harness.ex", "PII LEAK"},
    {"samen_core/lib/samen/pii_reads/harness.ex", "PARSE ERR"},
    {"samen_core/lib/samen/pii_reads/harness.ex", "[outside :reveal"},
    {"samen_core/lib/mix/tasks/samen.verify.pii_reads.ex",
     "refusing to run against an EMPTY PII registry"},
    # pii_classify
    {"samen_core/lib/samen/pii_classify.ex", "likely-PII column: "},
    # no_plaintext_pii
    {"samen_core/lib/mix/tasks/samen.verify.no_plaintext_pii.ex",
     "post-shred mode requires `--tiers all` (got "},
    {"samen_core/lib/samen/no_plaintext_pii/tier.ex", "EXEMPT (non_pii!)"},
    # migrations (down-check)
    {"samen_core/lib/samen/migration/down_check.ex", "down/0 FAILED — "},
    {"samen_core/lib/samen/migration/down_check.ex",
     "Every :expand migration must ship a tested, reversible down/0 (doc §runs 2b)."},
    {"samen_core/lib/samen/migration/down_check.ex", "did not roll back"},
    {"samen_core/lib/samen/migration/down_check.ex", "re-apply after down did not re-run this"},
    {"samen_core/lib/mix/tasks/samen.verify.migrations.ex", "migrations path does not exist: "},
    {"samen_core/lib/mix/tasks/samen.verify.migrations.ex",
     "no repo: pass --repo or set config :samen_core, :verify_repo"},
    # sink_schema
    {"samen_core/lib/samen/wide_event/schema.ex", "FORBIDDEN (name-carrier)"},
    {"samen_core/lib/samen/wide_event/schema.ex", "declares no closed `allowed:` set"},
    # metric_labels
    {"samen_core/lib/mix/tasks/samen.verify.metric_labels.ex", "[label-lint] FAIL:"},
    {"samen_core/lib/mix/tasks/samen.verify.metric_labels.ex", "uses forbidden tag "},
    {"samen_core/lib/mix/tasks/samen.verify.metric_labels.ex",
     "Raw org_id/actor_id/subject_id labels cause unbounded Prometheus cardinality."},
    {"samen_core/lib/mix/tasks/samen.verify.metric_labels.ex",
     "Use bounded labels: action, route, result, tenant_tier."},
    {"samen_core/lib/mix/tasks/samen.verify.metric_labels.ex",
     "label-lint: forbidden metric tags found — exit 1"},
    # vault_declared_parity
    {"samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex",
     "de-vaulted PII column: "},
    {"samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex",
     "matches the vault storage shape"},
    {"samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex",
     "discovered ZERO resources"},
    {"samen_core/lib/mix/tasks/samen.verify.vault_declared_parity.ex",
     "A vacuous parity check must not pass (fail-closed)."},
    # tnt_catalog
    {"samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex", "orphan tnt_field: org="},
    {"samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex", "uncatalogued custom field: "},
    {"samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex", "orphan custom-object field: org="},
    {"samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex", "orphan tnt_record: org="},
    {"samen_core/lib/mix/tasks/samen.verify.tnt_catalog.ex", "(no tnt_object row)"},
    # tnt_boundary
    {"samen_core/lib/mix/tasks/samen.verify.tnt_boundary.ex", "declares relationship"},
    {"samen_core/lib/mix/tasks/samen.verify.tnt_boundary.ex", "targets tenant-regime table"},
    # same_org_fk
    {"samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex", "declares belongs_to"},
    {"samen_core/lib/mix/tasks/samen.verify.same_org_fk.ex",
     "the scope-authoring guide §10 mandates a SameOrgFk guard on every org-scoped "},
    # no_pii_columns
    {"samen_core/lib/mix/tasks/samen.verify.no_pii_columns.ex",
     "matching the vault shape `pii_*`"},
    # aggregate_privacy
    {"samen_core/lib/mix/tasks/samen.verify.aggregate_privacy.ex",
     "declares no fail-closed cohort"},
    {"samen_core/lib/mix/tasks/samen.verify.aggregate_privacy.ex",
     "has no cohort_count_column (k-anon needs a cohort size)."},
    {"samen_core/lib/mix/tasks/samen.verify.aggregate_privacy.ex",
     "has empty value_columns (nothing to suppress when a floor fires)."},
    # api_contract
    {"samen_core/lib/samen/api_contract.ex",
     "was in the v1 contract but is no longer present"},
    {"samen_core/lib/samen/api_contract.ex",
     "was in the v1 contract but is no longer exposed"},
    {"samen_core/lib/samen/api_contract.ex", "changed type from"},
    {"samen_core/lib/samen/api_contract.ex", "NOTE: semantic breaks"},
    {"samen_core/lib/mix/tasks/samen.verify.api_contract.ex", "Snapshot file not found: "},
    # never_read_current (off-gate / Driftwood 16b)
    {"samen_core/lib/samen/cdc/never_read_current.ex",
     "against the CDC analytics repo in a module NOT marked"},
    {"samen_core/lib/samen/cdc/never_read_current.ex", "(doc line 635)"},
    {"samen_core/lib/mix/tasks/samen.verify.never_read_current.ex",
     "Nothing to lint — never-read-current is vacuously satisfied (tier default off)"}
  ]

  test "AC-G10-4: every quoted load-bearing error string exists in its verifier source" do
    failures = fragment_failures(gate_failures(), @error_evidence)
    assert failures == [], Enum.join(failures, "\n")
  end

  test "the shared failure shape is what halt_if_violations/2 actually prints" do
    src = source!("samen_core/lib/samen/verifier.ex")
    assert src =~ "FAIL: \#{task_name} found"
    assert src =~ "violation(s):"
    assert gate_failures() =~ "found N violation(s):"
  end

  test "RED PATH: a fabricated error string fails the fragment checker" do
    doc = gate_failures() <> "\nthis error was never printed by anything\n"

    fake = [
      {"samen_core/lib/samen/verifier.ex", "this error was never printed by anything"}
    ]

    assert [failure] = fragment_failures(doc, fake)
    assert failure =~ "verifier.ex"
    assert failure =~ "never printed"

    # Positive control: the real table against the real doc is green.
    assert fragment_failures(gate_failures(), @error_evidence) == []
  end

  # Both-ways parity: the fragment must be in the DOC (quoted error) and the SOURCE
  # (what the gate prints). Either side missing is a failure message.
  defp fragment_failures(doc, evidence) do
    Enum.flat_map(evidence, fn {rel_path, fragment} ->
      src = source!(rel_path)

      cond do
        not String.contains?(src, fragment) ->
          ["#{rel_path} no longer prints #{inspect(fragment)} — gate-failures.md drifted"]

        not String.contains?(doc, fragment) ->
          ["gate-failures.md does not quote #{inspect(fragment)} (from #{rel_path}) — evidence table drifted"]

        true ->
          []
      end
    end)
  end
end
