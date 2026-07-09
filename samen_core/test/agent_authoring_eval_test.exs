defmodule SamenCore.AgentAuthoringEvalTest do
  @moduledoc """
  # Agent-authoring eval (T6.3, plan §7 Phase 6)

  The vision doc's "why it's the substrate for software an agent builds"
  (`docs/samen-foundry.txt` :921–:923): an agent asked to build a SaaS off a
  blank schema *invents* a users table, guesses a type, pastes an email into a
  free-text column. **Samen removes the blank page.** The catalog is ground the
  agent grounds on and can't invent off of; the fail-closed verifier gate is the
  agent's correctness oracle — a hallucinated column fails the build, net-new PII
  is caught by `pii_classify`.

  This is a **runnable eval** that puts that claim under test. It models "an agent
  authored these resource changes" and APPLIES each seeded change to a scratch
  host (the `SamenCore.TestRepo` fixture DB, in-sandbox, or a project-local scratch
  source dir), then asserts the **gate's exact exit behavior** — using the SAME
  `check/*` / `violations/*` / `scan/*` entry points each `mix samen.verify.*` task
  runs immediately before `Samen.Verifier.halt_if_violations/2`.

  The exit contract (`Samen.Verifier.halt_if_violations/2`) is precisely:

      violations == []  →  banner + exit 0   (the agent's change PASSES the gate)
      violations != []  →  print   + halt(1) (the gate CATCHES the agent's wrong)

  So `violations == []` is a deterministic proxy for exit 0, and a non-empty list
  is a deterministic proxy for exit 1. For case 2 we ALSO drive a real
  `System.cmd/3` child OS process to observe the true `:erlang.halt(1)` exit code
  end-to-end (the moduledoc of `Samen.Verifier` names this as the faithful way to
  assert the exit code without terminating the test VM).

  ## The scoring rubric (`@rubric`)

  Each seeded case names: the authored wrong, the OWNING verifier, the expected
  gate exit, and a substring the diagnostic must carry so the agent gets an
  *actionable* correctness signal (not just a red light). A case SCORES `:pass`
  iff the owning verifier produced the expected exit AND the diagnostic named the
  offending item. The final test asserts every case scored `:pass` — the eval's
  own gate.

  | # | seeded wrong (what the agent got wrong)                  | owning verifier         | expect |
  |---|---------------------------------------------------------|-------------------------|--------|
  | 1 | a CORRECT new resource (vaulted PII, guarded FK, no leak)| the whole gate          | exit 0 |
  | 2 | a hallucinated / uncatalogued column                    | catalog_parity + column_refs | exit 1 |
  | 3 | net-new plaintext PII (`attribute :ssn, :string`)       | pii_classify            | exit 1 |
  | 4 | an unprefixed physical column                           | prefixes                | exit 1 |
  | 5 | a vault value logged OUTSIDE a `:reveal` action         | pii_reads               | exit 1 |
  | 6 | a `belongs_to` FK with no `SameOrgFk` guard             | same_org_fk             | exit 1 |

  These 6 red paths (cases 2–6 must-fail, case 1 must-pass) ARE the eval's red
  paths per the task spec.

  ## Anti-tautology probe (HARD RULE §2)

  Run this session in a project-local scratch backup
  (`samen_core/tmp/agent_eval_scratch/`, git-ignored, removed after). I sabotaged
  ONE gate step — `Mix.Tasks.Samen.Verify.PiiClassify.check/3` — to always return
  `[]` (the fail-open bug an agent's oracle must never have). **Observed:** eval
  case 3 (net-new plaintext PII) FLIPPED from `:pass` (caught) to `:fail`
  (uncaught) — the exact "the oracle stopped catching" outcome the task requires —
  while cases 1/2/4/5/6 stayed green (proving the sabotage was surgical, not a
  blanket break). **Reverted:** the file is byte-identical to the original and case
  3 catches again. The scratch dir was removed. Result stated in the T6.3 report.

  Every "caught" assertion below also carries a NON-VACUOUS positive control (case
  1 proves the same verifier passes a correct resource), so a red path can never
  pass by the verifier being always-fail.
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo

  alias Mix.Tasks.Samen.Verify.{CatalogParity, ColumnRefs, PiiClassify, Prefixes, SameOrgFk}
  alias Samen.PiiReads
  alias Samen.PiiReads.Registry

  # The correct + wrong fixtures the "agent" authored. These are already-migrated,
  # already-registered fixtures the substrate ships for exactly these red paths —
  # so the eval composes them into the agent-authoring narrative rather than
  # minting a parallel set that could drift from the verifiers' own tests.
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias SamenCore.Support.PiiClassify.PersonRecord, as: PlaintextPiiRecord
  alias SamenCore.Support.SameOrgFkFixture

  @project_dir Path.expand("../", __DIR__)
  @scratch_root Path.join([__DIR__, "..", "tmp", "agent_eval_scratch"])

  # ADR-015 (default-deny): `RevealPerson.:display_name` is a pre-existing benign-
  # named freeform :string. Under default-deny it is flagged UNLESS it is in the
  # committed baseline (a reviewed, pre-existing column — exactly what
  # `schema.dict.json` records per §4.3). CASE 1 is the positive control ("a
  # correctly-authored resource passes"), so we model the fixture's freeform column
  # as baseline-covered — the correct-authorship state under the new rule. A NET-NEW
  # freeform/PII column (CASE 3) is NOT in this baseline and still flags.
  @correctly_authored_baseline MapSet.new([{"rvp_reveal_person", "rvp_display_name"}])

  # The scoring rubric: case_id => {label, owning_verifier, expected_exit}.
  @rubric %{
    1 => {"a correct new resource passes the whole gate", :gate, :exit_0},
    2 => {"a hallucinated / uncatalogued column", :catalog_parity_column_refs, :exit_1},
    3 => {"net-new plaintext PII (attribute :ssn, :string)", :pii_classify, :exit_1},
    4 => {"an unprefixed column", :prefixes, :exit_1},
    5 => {"a vault value logged outside :reveal", :pii_reads, :exit_1},
    6 => {"a missing SameOrgFk guard", :same_org_fk, :exit_1}
  }

  setup context do
    if context[:exit_code] do
      # Exit-code cases run a child OS process against a direct connection; no
      # sandbox checkout (the child has its own DB connection).
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
      :ok
    end
  end

  # ==========================================================================
  # CASE 1 — a CORRECT new resource passes the gate (exit 0)
  #
  # The positive control for the whole eval: the substrate does not just fail an
  # agent's wrong — it PASSES an agent's right. `RevealPerson` (vault-routed PII +
  # a declared `:reveal_email` boundary) and `SameOrgFkFixture.Guarded` (an
  # org-scoped belongs_to WITH a SameOrgFk guard) are correctly-authored resources.
  # Every verifier that owns a rule must be GREEN on them.
  # ==========================================================================

  describe "CASE 1 — a correctly-authored resource passes the gate (exit 0)" do
    test "pii_classify does NOT flag a resource whose PII is vault-routed" do
      # RevealPerson vaults :emails; its only freeform column (:display_name) is a
      # reviewed, baseline-covered column (ADR-015 default-deny → baseline clears it).
      violations = PiiClassify.check([RevealPerson], @correctly_authored_baseline)

      assert violations == [],
             "a correctly-vaulted PII resource must PASS pii_classify (exit 0), got: #{inspect(violations)}"
    end

    test "same_org_fk does NOT flag a belongs_to that carries a SameOrgFk guard" do
      violations = SameOrgFk.violations(domain: to_string(SameOrgFkFixture))

      refute Enum.any?(violations, &(&1 =~ "Guarded")),
             "the guarded FK resource must PASS same_org_fk (exit 0), got: #{inspect(violations)}"
    end

    test "pii_reads does NOT flag a vault value used inside its declared :reveal action" do
      reg = Registry.build(resources: [RevealPerson])

      src = ~S'''
      defmodule SamenCore.Support.RevealDomain.RevealPerson do
        require Logger
        action :reveal_email, :string do
          # Inside the DECLARED reveal boundary — this is the ONE sanctioned egress.
          Logger.info("revealed=#{subject.emails}")
        end
      end
      '''

      findings = PiiReads.scan_source("reveal_person.ex", src, reg)
      direct = Enum.filter(findings, &(&1.kind == :direct_leak))

      assert direct == [],
             "a vault value INSIDE a declared reveal action must PASS pii_reads (exit 0), got: #{inspect(direct)}"
    end

    test "catalog_parity + prefixes are GREEN on the clean fixture host (exit 0)" do
      assert CatalogParity.check(TestRepo) == [],
             "the fully-catalogued fixture host must PASS catalog_parity"

      assert Prefixes.check(TestRepo) == [],
             "the fully-prefixed fixture host must PASS prefixes"
    end
  end

  # ==========================================================================
  # CASE 2 — a hallucinated / uncatalogued column FAILS catalog_parity/column_refs
  #
  # The doc's headline: "a hallucinated field doesn't compile." Two shapes:
  #   (a) source referencing a column that is NOT in fld_field → column_refs;
  #   (b) a physical DB column with no fld_field row → catalog_parity.
  # ==========================================================================

  describe "CASE 2 — a hallucinated / uncatalogued column FAILS (exit 1)" do
    test "column_refs FAILS on a source reference to an uncatalogued column" do
      scratch = make_scratch_dir("case2_colrefs")

      File.write!(Path.join(scratch, "agent_authored.ex"), """
      defmodule Agent.Authored do
        # The agent grounded on the WRONG name — `drv_license` is not in the catalog.
        def dispatch(row), do: row.drv_license
      end
      """)

      violations = ColumnRefs.check(TestRepo, [scratch])

      assert violations != [],
             "column_refs MUST FAIL on an uncatalogued column reference (exit 1)"

      assert Enum.any?(violations, &(&1 =~ "drv_license")),
             "the diagnostic must NAME the hallucinated column, got: #{inspect(violations)}"
    end

    test "catalog_parity FAILS on a physical column with no fld_field row" do
      # The agent added a column to the DDL but forgot to catalog it. Seed it
      # in-sandbox on a managed table; the sandbox rolls it back at test end.
      {:ok, _} =
        TestRepo.query(
          "ALTER TABLE com_contact ADD COLUMN com_hallucinated text"
        )

      violations = CatalogParity.check(TestRepo)

      assert Enum.any?(violations, fn v ->
               v =~ "com_contact.com_hallucinated" and v =~ "uncatalogued"
             end),
             "catalog_parity MUST FAIL naming the uncatalogued column (exit 1), got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # CASE 3 — net-new plaintext PII (attribute :ssn, :string) FAILS pii_classify
  #
  # The doc's exact scenario (:923): "the agent writes attribute :ssn, :string with
  # a real type and no pii_ prefix, landing plaintext at rest — caught by
  # mix samen.verify.pii_classify before it merges." `PlaintextPiiRecord` has a
  # plain `:ssn, :string` (and other PII-named plain columns) and NO pii do block.
  # ==========================================================================

  describe "CASE 3 — net-new plaintext PII FAILS pii_classify (exit 1)" do
    test "pii_classify FAILS on a plain `attribute :ssn, :string`" do
      # Empty baseline + empty registry: every plain-typed column is "new" and
      # uncleared — exactly an agent authoring a fresh resource off the catalog.
      violations = PiiClassify.check([PlaintextPiiRecord], MapSet.new(), [])

      assert violations != [],
             "pii_classify MUST FAIL on a plain :ssn column (exit 1)"

      assert Enum.any?(violations, &(&1 =~ "ssn")),
             "the diagnostic must NAME the plaintext PII column :ssn, got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # CASE 4 — an unprefixed column FAILS prefixes
  #
  # Self-qualifying storage: every column carries its resource abbrev. An agent
  # hand-writing a migration with a bare column name breaks the convention. Seed
  # an unprefixed physical column on a managed table (in-sandbox); prefixes flags
  # it against the resource's abbrev.
  # ==========================================================================

  describe "CASE 4 — an unprefixed column FAILS prefixes (exit 1)" do
    test "prefixes FAILS on a physical column with no abbrev prefix" do
      {:ok, _} =
        TestRepo.query(
          "ALTER TABLE com_contact ADD COLUMN raw_ssn text"
        )

      violations = Prefixes.check(TestRepo)

      assert Enum.any?(violations, fn v ->
               v =~ "raw_ssn" and v =~ "unprefixed column"
             end),
             "prefixes MUST FAIL naming the unprefixed column + expected prefix (exit 1), got: #{inspect(violations)}"

      assert Enum.any?(violations, &(&1 =~ "com_")),
             "the diagnostic must name the EXPECTED prefix so the agent can fix it, got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # CASE 5 — a vault value logged OUTSIDE :reveal FAILS pii_reads
  #
  # The plaintext-to-sink path the doc calls out: a vault-routed value reaching a
  # log/span outside the ONE sanctioned `:reveal` egress. The registry taints the
  # vault-declared field (:emails / :rvp_emails); the walker flags the sink unless
  # it sits inside a DECLARED reveal action.
  # ==========================================================================

  describe "CASE 5 — a vault value logged outside :reveal FAILS pii_reads (exit 1)" do
    test "pii_reads FAILS on a vault value flowing to Logger outside a reveal action" do
      reg = Registry.build(resources: [RevealPerson])

      src = ~S'''
      defmodule Agent.LeakyReport do
        require Logger
        def summarize(subject) do
          # LEAK: a vault-routed value in a log line, NOT inside a reveal action.
          Logger.info("subscriber email=#{subject.rvp_emails}")
        end
      end
      '''

      findings = PiiReads.scan_source("leaky_report.ex", src, reg)
      direct = Enum.filter(findings, &(&1.kind == :direct_leak))

      assert direct != [],
             "pii_reads MUST FAIL on a vault value logged outside :reveal (exit 1)"

      assert Enum.all?(direct, &(&1.scope == :out_of_reveal)),
             "the leak must be scoped :out_of_reveal, got: #{inspect(direct)}"
    end
  end

  # ==========================================================================
  # CASE 6 — a missing SameOrgFk guard FAILS same_org_fk
  #
  # A cross-tenant hazard: an org-scoped belongs_to with no SameOrgFk change can
  # store a dangling cross-tenant FK. `SameOrgFkFixture.Unguarded` is exactly that.
  # ==========================================================================

  describe "CASE 6 — a missing SameOrgFk guard FAILS same_org_fk (exit 1)" do
    test "same_org_fk FAILS on an org-scoped belongs_to with no SameOrgFk change" do
      violations = SameOrgFk.violations(domain: to_string(SameOrgFkFixture))

      assert Enum.any?(violations, fn v ->
               v =~ "Unguarded" and v =~ ":parent"
             end),
             "same_org_fk MUST FAIL naming the unguarded FK (exit 1), got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # TRUE EXIT-CODE PROOF — case 2 through a real child OS process
  #
  # The check/* assertions above are a faithful proxy for the exit code (the task
  # halts iff violations != []). This test proves the end-to-end `:erlang.halt`
  # code by spawning `mix samen.verify.catalog_parity` in a child OS process with
  # an uncatalogued column seeded via a DIRECT (non-sandbox) connection the child
  # can see, then asserting exit == 1 and the diagnostic names the column.
  # ==========================================================================

  describe "TRUE exit-code proof (child OS process)" do
    @tag :exit_code
    test "the catalog_parity mix task exits 1 on an uncatalogued column" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS com_agent_ghost text",
          []
        )
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(
            conn,
            "ALTER TABLE com_contact DROP COLUMN IF EXISTS com_agent_ghost",
            []
          )
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.catalog_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "the gate MUST exit 1 (halt/1) on an uncatalogued column, got #{exit_code}.\n#{output}"

      assert output =~ "com_agent_ghost",
             "the child-process diagnostic must name the uncatalogued column, got:\n#{output}"
    end

    @tag :exit_code
    test "the catalog_parity mix task exits 0 on the clean host (the correct-resource control)" do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.catalog_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 0,
             "the gate MUST exit 0 on a correctly-catalogued host (case-1 control), got #{exit_code}.\n#{output}"
    end
  end

  # ==========================================================================
  # THE EVAL'S OWN GATE — every case must score :pass
  #
  # Re-runs all six cases through their owning verifier and scores each against
  # the rubric. A case scores :pass iff the owning verifier produced the expected
  # exit. This is the harness the task asks for: the scoring rubric run THROUGH
  # the verifier gate as the pass/fail.
  # ==========================================================================

  describe "the eval scores every seeded case against the rubric" do
    test "all six cases score :pass (the substrate makes the agent's wrong bounded/caught)" do
      scores = Map.new(1..6, fn id -> {id, score_case(id)} end)

      failed = for {id, :fail} <- scores, do: id

      assert failed == [],
             "eval cases scored :fail: #{inspect(failed)}. Full scores: #{inspect(scores)}\n" <>
               "Rubric: #{inspect(@rubric)}"

      # Non-vacuity: prove the scorer is a real discriminator, not always-:pass —
      # a case the scorer expects to CATCH would score :fail if the verifier went
      # silent. (The anti-tautology probe in the moduledoc exercises that flip
      # against the real verifier; here we assert the scores map is fully populated
      # and every value is :pass, both of which a stubbed-out scorer would break.)
      assert map_size(scores) == 6
      assert Enum.all?(Map.values(scores), &(&1 == :pass))
    end
  end

  # --------------------------------------------------------------------------
  # Scoring: run each seeded case through its owning verifier and compare the
  # exit (empty violations = exit 0, non-empty = exit 1) to the rubric.
  # --------------------------------------------------------------------------

  defp score_case(1) do
    # exit 0: correct resource passes every owning verifier.
    pii_ok? = PiiClassify.check([RevealPerson], @correctly_authored_baseline) == []
    fk_ok? = not Enum.any?(SameOrgFk.violations(domain: to_string(SameOrgFkFixture)), &(&1 =~ "Guarded"))
    parity_ok? = CatalogParity.check(TestRepo) == []
    prefixes_ok? = Prefixes.check(TestRepo) == []

    if pii_ok? and fk_ok? and parity_ok? and prefixes_ok?, do: :pass, else: :fail
  end

  defp score_case(2) do
    scratch = make_scratch_dir("score2")

    File.write!(Path.join(scratch, "x.ex"), """
    defmodule X do
      def f(r), do: r.drv_license
    end
    """)

    caught? = Enum.any?(ColumnRefs.check(TestRepo, [scratch]), &(&1 =~ "drv_license"))
    if caught?, do: :pass, else: :fail
  end

  defp score_case(3) do
    caught? =
      PiiClassify.check([PlaintextPiiRecord], MapSet.new(), [])
      |> Enum.any?(&(&1 =~ "ssn"))

    if caught?, do: :pass, else: :fail
  end

  defp score_case(4) do
    {:ok, _} = TestRepo.query("ALTER TABLE com_contact ADD COLUMN score4_raw text")
    caught? = Enum.any?(Prefixes.check(TestRepo), &(&1 =~ "score4_raw"))
    # sandbox rolls back the ALTER at test end
    if caught?, do: :pass, else: :fail
  end

  defp score_case(5) do
    reg = Registry.build(resources: [RevealPerson])

    src = ~S'''
    defmodule Y do
      require Logger
      def f(s), do: Logger.info("e=#{s.rvp_emails}")
    end
    '''

    caught? =
      PiiReads.scan_source("y.ex", src, reg)
      |> Enum.any?(&(&1.kind == :direct_leak))

    if caught?, do: :pass, else: :fail
  end

  defp score_case(6) do
    caught? =
      SameOrgFk.violations(domain: to_string(SameOrgFkFixture))
      |> Enum.any?(&(&1 =~ "Unguarded"))

    if caught?, do: :pass, else: :fail
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp make_scratch_dir(name) do
    base = Path.expand(Path.join(@scratch_root, "#{name}_#{System.unique_integer([:positive])}"))
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  # A direct (non-sandbox) Postgrex connection so a seeded DDL is visible to a
  # child OS process (which has its own connection). Copied from the pattern in
  # verify_prefixes_test.exs.
  defp with_direct_connection(fun) do
    raw_config =
      TestRepo.config()
      |> Keyword.drop([
        :pool,
        :pool_size,
        :telemetry_prefix,
        :installed_extensions,
        :otp_app,
        :migration_primary_key,
        :default_prefix
      ])

    {:ok, conn} = Postgrex.start_link(raw_config)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end
end
