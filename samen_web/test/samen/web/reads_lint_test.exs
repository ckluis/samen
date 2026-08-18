defmodule Samen.Web.Reads.LintTest do
  @moduledoc """
  The EXHAUSTIVE `read!`-elimination lint (AC-G1-5, A3-GATE-2 closure) — the
  completeness companion to `reads_bounded_test.exs`.

  `bounded!/4` is opt-in per function; a reads fn no test opted in was invisible to the
  gate — exactly how `CRM.Reads.pipeline/2` and the chat reads shipped unbounded behind
  mounted LiveViews (A3-GATE-1). This suite closes the hole:

    * **GREEN (completeness)** — `Lint.assert_all_bounded!/0` sweeps EVERY `reads.ex`
      under `lib/samen/web/` and passes only if every read-bearing clause carries an
      explicit bound. New reads modules/functions are swept in automatically; a future
      unconverted read FAILS this test instead of silently mounting unbounded.
    * **Non-vacuity** — the sweep must actually SEE every known reads module and a
      realistic number of read clauses; a glob/AST-matcher regression that matches
      nothing cannot green-light the gate.
    * **RED (A3-GATE-1 shape)** — a fixture module with a raw `Ash.read!` and no limit
      (the EXACT pre-fix shape of `chat/reads.ex threads/2`) is flagged, and
      `assert_all_bounded!` RAISES over it. Anti-tautology: the SAME fixture with the
      one-line `Ash.Query.limit` fix passes — the lint discriminates, it is not a no-op.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Reads.Lint
  alias Samen.Web.Reads.UnboundedReadError

  @known_reads_modules ~w(billing chat crm marketing operator support)

  # The EXACT pre-fix A3-GATE-1 shape: chat/reads.ex threads/2 before this phase —
  # a mounted list read with sort but NO limit.
  @unbounded_fixture """
  defmodule Samen.Web.Fixture.UnboundedReads do
    require Ash.Query
    alias Samen.Web.Mount

    def threads(mount, scope) do
      Mount.resource(mount, ChatThread)
      |> Ash.Query.ensure_selected([:subject, :kind, :status])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(scope: scope)
    rescue
      _ -> []
    end
  end
  """

  # The SAME module with the one-line A3 fix applied.
  @bounded_fixture """
  defmodule Samen.Web.Fixture.BoundedReads do
    require Ash.Query
    alias Samen.Web.Mount

    @detail_limit 200

    def threads(mount, scope) do
      Mount.resource(mount, ChatThread)
      |> Ash.Query.ensure_selected([:subject, :kind, :status])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    rescue
      _ -> []
    end

    def threads_page(mount, scope, state) do
      Mount.resource(mount, ChatThread)
      |> Samen.Web.Reads.page!(state, scope: scope)
    end

    def get_thread(mount, scope, id) do
      Mount.resource(mount, ChatThread)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)
    end

    def metrics(mount, scope) do
      Ash.count!(Mount.resource(mount, ChatThread), scope: scope)
    end
  end
  """

  # ---------------------------------------------------------------------------
  # GREEN — completeness over the SHIPPED reads layer
  # ---------------------------------------------------------------------------

  test "GREEN (AC-G1-5): EVERY read in EVERY samen_web reads module is bounded — no opt-in required" do
    assert {:ok, %{files: file_count, read_clauses: read_clauses}} = Lint.assert_all_bounded!()

    # Non-vacuity: the sweep saw the whole reads layer, not an empty glob. 6 vertical
    # reads modules + the Samen.Web.Reads builder itself = at least 7 files, and the
    # layer holds dozens of read-bearing clauses — a matcher that finds none is broken.
    assert file_count >= 7
    assert read_clauses >= 30
  end

  test "COMPLETENESS ROLL-CALL: the sweep covers every known reads module (a glob regression cannot shrink coverage silently)" do
    files = Lint.reads_files()

    for module_dir <- @known_reads_modules do
      assert Enum.any?(files, &String.ends_with?(&1, "/#{module_dir}/reads.ex")),
             "the lint sweep no longer covers lib/samen/web/#{module_dir}/reads.ex — " <>
               "an unbounded read there would be invisible to the gate (A3-GATE-2)"
    end

    # The keyset builder itself is under lint too (its page!/3 performs the Ash.read!).
    assert Enum.any?(files, &String.ends_with?(&1, "/web/reads.ex"))
  end

  # ---------------------------------------------------------------------------
  # VERTICAL COVERAGE — ADR-045 §4.2 (O8): the lint sweeps the shipped vertical read
  # layers, not just samen_web. Before this, driftwood/pawchart reads were one directory
  # outside the scanner and an unbounded vertical read (driver_roster/1) was invisible.
  # ---------------------------------------------------------------------------

  @vertical_reads [
    "/driftwood/lib/driftwood/reads.ex",
    "/pawchart/lib/pawchart_web/clinic_reads.ex"
  ]

  test "VERTICAL COVERAGE (O8): the sweep now includes the driftwood + pawchart read layers" do
    files = Lint.reads_files()
    vertical = Lint.vertical_reads_files()

    for suffix <- @vertical_reads do
      assert Enum.any?(files, &String.ends_with?(&1, suffix)),
             "the lint no longer sweeps #{suffix} — an unbounded vertical read there would be " <>
               "invisible to the gate (the exact O8 defect: A3-GATE-1 one dir outside the scanner)"

      assert Enum.any?(vertical, &String.ends_with?(&1, suffix)),
             "#{suffix} is not in vertical_reads_files/0"
    end

    # Non-vacuity: the vertical globs actually resolved to files on disk (a broken path
    # arithmetic that matched nothing would silently un-cover the verticals).
    assert length(vertical) >= 2
  end

  test "VERTICAL REGRESSION PIN (O8): the driftwood + pawchart read layers scan CLEAN AND non-vacuously" do
    for suffix <- @vertical_reads do
      file = Enum.find(Lint.reads_files(), &String.ends_with?(&1, suffix))
      assert file, "#{suffix} missing from the sweep"

      {violations, read_clauses} = file |> File.read!() |> Lint.scan_source(file)

      assert violations == [],
             "#{suffix} has an UNBOUNDED read (O8): #{inspect(violations)} — bound it via " <>
               "Ash.Query.limit or Samen.Web.Reads.page!/3"

      # Non-vacuous: the scanner genuinely saw this vertical module's reads.
      assert read_clauses > 0
    end
  end

  test "VERTICAL RED PATH (O8): a synthetic UNBOUNDED vertical read is FLAGGED (the coverage is not cosmetic)" do
    # A driftwood-shaped unbounded roster read (the pre-fix driver_roster/1 shape) — proves the
    # extended sweep would actually catch a future unbounded vertical read, not merely list the
    # files. Path is vertical-shaped; the scanner is path-agnostic, so this is the same
    # discriminator the framework RED path uses, aimed at the vertical tree.
    vertical_unbounded = """
    defmodule Driftwood.Fixture.UnboundedReads do
      require Ash.Query

      def driver_roster(scope) do
        Driftwood.Freight.Driver
        |> Ash.Query.sort(inserted_at: :asc)
        |> Ash.read!(scope: scope)
      rescue
        _ -> []
      end
    end
    """

    {violations, read_clauses} =
      Lint.scan_source(vertical_unbounded, "driftwood/lib/driftwood/reads.ex")

    assert read_clauses == 1
    assert [%{fun: :driver_roster, arity: 1}] = violations
  end

  test "REGRESSION PIN (A3-GATE-1): the two modules the A3 gate caught unbounded now scan clean AND non-vacuously" do
    for module_dir <- ["chat", "crm"] do
      file = Enum.find(Lint.reads_files(), &String.ends_with?(&1, "/#{module_dir}/reads.ex"))
      assert file, "#{module_dir}/reads.ex missing from the sweep"

      {violations, read_clauses} = file |> File.read!() |> Lint.scan_source(file)

      assert violations == [],
             "#{module_dir}/reads.ex regressed to unbounded reads: #{inspect(violations)}"

      # Non-vacuous: the scanner genuinely saw this module's reads.
      assert read_clauses > 0
    end
  end

  # ---------------------------------------------------------------------------
  # RED — the lint discriminates (anti-tautology)
  # ---------------------------------------------------------------------------

  test "RED PATH (A3-GATE-1 shape): a raw sorted Ash.read! with no limit is FLAGGED with fun + line" do
    {violations, read_clauses} = Lint.scan_source(@unbounded_fixture, "fixture/unbounded_reads.ex")

    assert read_clauses == 1
    assert [%{fun: :threads, arity: 2, file: "fixture/unbounded_reads.ex", line: line}] = violations
    assert is_integer(line) and line > 0
  end

  test "RED PATH: assert_all_bounded! RAISES loudly over an unbounded reads file — never a silent green" do
    dir = Path.join(System.tmp_dir!(), "samen_reads_lint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "reads.ex")
    File.write!(file, @unbounded_fixture)

    try do
      err =
        assert_raise UnboundedReadError, fn ->
          Lint.assert_all_bounded!([file])
        end

      assert err.message =~ "UNBOUNDED READ"
      assert err.message =~ "threads/2"
    after
      File.rm_rf!(dir)
    end
  end

  test "ANTI-TAUTOLOGY: the SAME fixture with the one-line limit fix PASSES — the lint discriminates, it is not a no-op" do
    # If the scanner were a no-op (never flags), the RED tests above would fail; if it
    # flagged everything (always red), THIS would fail. Together they prove it reads
    # the AST and keys on the bound.
    {violations, read_clauses} = Lint.scan_source(@bounded_fixture, "fixture/bounded_reads.ex")

    assert violations == []
    # threads (limit) and get_thread (read_one! + limit 1) are the read-bearing clauses.
    # threads_page contains no literal Ash read — it delegates to Samen.Web.Reads.page!/3,
    # whose OWN clause is under lint (each read site is checked exactly where it appears).
    # metrics (Ash.count!) is an aggregate and intentionally NOT counted.
    assert read_clauses == 2
  end
end
