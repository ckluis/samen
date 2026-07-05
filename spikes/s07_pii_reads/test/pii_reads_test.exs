defmodule PiiReadsTest do
  use ExUnit.Case, async: true

  alias PiiReads.{Harness, CorpusLabels}

  @leaks_dir CorpusLabels.path("leaks")
  @clean_dir CorpusLabels.path("clean")
  @laundered_dir CorpusLabels.path("laundered")

  defp scan!(dir) do
    {:ok, findings} = PiiReads.scan_dir(dir)
    findings
  end

  defp direct(findings), do: Enum.filter(findings, &(&1.kind == :direct_leak))

  # ---------------------------------------------------------------------------
  # GREEN PATH — catches ALL direct leaks
  # ---------------------------------------------------------------------------

  test "catches every seeded direct leak (catch rate = 100%)" do
    found = @leaks_dir |> scan!() |> direct()
    assert length(found) == CorpusLabels.direct_leak_count()

    # Each labeled leak must correspond to a finding at the expected line with
    # the expected pii attribute(s).
    for {rel, line, pii} <- CorpusLabels.direct_leaks() do
      match =
        Enum.find(found, fn f ->
          String.ends_with?(f.file, rel) and f.line == line
        end)

      assert match, "missed seeded direct leak at #{rel}:#{line}"
      assert Enum.sort(match.pii) == Enum.sort(pii)
    end
  end

  test "every leak file finding is scoped :out_of_reveal" do
    for f <- @leaks_dir |> scan!() |> direct() do
      assert f.scope == :out_of_reveal
    end
  end

  test "harness returns exit code 1 for the leak corpus" do
    {code, _findings} = Harness.check_dirs([@leaks_dir])
    assert code == 1
  end

  # ---------------------------------------------------------------------------
  # ZERO false positives on declaration + reveal sites (acceptance criterion)
  # ---------------------------------------------------------------------------

  test "zero false positives on the clean corpus (declarations + reveal + non-pii)" do
    found = scan!(@clean_dir)
    assert found == [], "false positives: #{inspect(found)}"
  end

  test "harness returns exit code 0 for the clean corpus (RED PATH clean side)" do
    {code, _findings} = Harness.check_dirs([@clean_dir])
    assert code == 0
  end

  test "pii_attribute declaration sites are NOT flagged" do
    # `pii do pii_attribute :per_full_name ... end` names the pii field but is a
    # declaration, not a flow. A grep for `pii_` flags it; the walker must not.
    src = """
    defmodule R do
      use Samen.Resource
      pii do
        pii_attribute(:per_full_name, Samen.Type.FullName, vault: :pii_name)
        pii_attribute(:pii_ssn, :string, vault: :pii_ssn)
      end
    end
    """

    assert PiiReads.scan_source("decl.ex", src) == []
  end

  # ---------------------------------------------------------------------------
  # Reveal-scope suppression is LOAD-BEARING (not vacuous)
  # ---------------------------------------------------------------------------

  test "the SAME sink body is flagged outside :reveal but suppressed inside it" do
    inside = ~S"""
    defmodule T do
      def reveal(s) do
        Logger.info("name=#{s.per_full_name}")
      end
    end
    """

    outside = ~S"""
    defmodule T do
      def show(s) do
        Logger.info("name=#{s.per_full_name}")
      end
    end
    """

    assert PiiReads.scan_source("inside.ex", inside) == [],
           "reveal-scoped sink must be suppressed"

    outside_findings = PiiReads.scan_source("outside.ex", outside)
    assert length(outside_findings) == 1, "non-reveal sink must be flagged"
    assert hd(outside_findings).pii == [:per_full_name]
  end

  test "action :reveal do ... end scope suppresses a sink" do
    src = ~S"""
    defmodule T do
      action :reveal do
        Logger.info("n=#{subject.pii_ssn}")
      end
    end
    """

    assert PiiReads.scan_source("act.ex", src) == []
  end

  # ---------------------------------------------------------------------------
  # LAUNDERED leaks — documented EXPECTED MISSES (layered design)
  # ---------------------------------------------------------------------------

  test "laundered leaks are missed by the AST layer (expected, by design)" do
    # This asserts the HONEST boundary: a pure AST match does not catch pii
    # laundered through a helper. If a future change accidentally "catches" one
    # via an over-broad rule, this test surfaces it so the claim stays honest.
    found = scan!(@laundered_dir)

    assert direct(found) == [],
           "laundered leaks were flagged — the honest expected-miss boundary changed; " <>
             "re-examine whether the walker became unsoundly broad"
  end

  # ---------------------------------------------------------------------------
  # RED PATH — the harness fails closed when a seeded direct leak is present
  # ---------------------------------------------------------------------------

  test "RED PATH: harness exits 1 when a direct leak is present, 0 when removed" do
    # With the leak: must be non-zero (fail closed).
    leaky = ~S"""
    defmodule Bad do
      def go(c), do: Logger.info("ssn=#{c.pii_ssn}")
    end
    """

    {leaky_code, leaky_findings} = Harness.check_sources([{"bad.ex", leaky}])
    assert leaky_code == 1, "a seeded direct leak MUST make the harness fail closed"
    assert length(direct(leaky_findings)) == 1

    # Same code with the leak removed (log a bounded token instead): must be 0.
    clean = ~S"""
    defmodule Good do
      def go(c), do: Logger.info("id=#{c.com_org_id}")
    end
    """

    {clean_code, clean_findings} = Harness.check_sources([{"good.ex", clean}])
    assert clean_code == 0, "clean code must pass (exit 0)"
    assert clean_findings == []
  end

  test "RED PATH meta-check: the assertion actually depends on the leak" do
    # A red-path test that passes when it should fail is worthless. Prove the
    # oracle discriminates: identical structure, one has pii, one does not.
    with_pii = ~S"""
    defmodule A do
      def f(x), do: IO.puts("#{x.pii_dob}")
    end
    """

    without_pii = ~S"""
    defmodule A do
      def f(x), do: IO.puts("#{x.com_created_at}")
    end
    """

    {c1, _} = Harness.check_sources([{"a.ex", with_pii}])
    {c2, _} = Harness.check_sources([{"a.ex", without_pii}])

    assert c1 == 1
    assert c2 == 0
    refute c1 == c2, "the exit code must be a function of the pii presence"
  end

  # ---------------------------------------------------------------------------
  # Fail-closed on unparseable source (does not silently skip)
  # ---------------------------------------------------------------------------

  test "unparseable source is a parse_error finding (fail closed, exit 1)" do
    {code, findings} = Harness.check_sources([{"broken.ex", "defmodule X do def"}])
    assert code == 1
    assert Enum.any?(findings, &(&1.kind == :parse_error))
  end

  # ---------------------------------------------------------------------------
  # Numeric metrics (catch rate / false-positive rate) — plan S0.7 findings
  # ---------------------------------------------------------------------------

  test "reports catch rate and false-positive rate numerically" do
    direct_found = @leaks_dir |> scan!() |> direct()
    fp_found = @clean_dir |> scan!()

    catch_rate = length(direct_found) / CorpusLabels.direct_leak_count()
    fp_count = length(fp_found)
    fp_per_50 = fp_count / CorpusLabels.legit_sink_sites() * 50

    IO.puts("\n--- pii_reads metrics ---")
    IO.puts("direct leaks seeded:   #{CorpusLabels.direct_leak_count()}")
    IO.puts("direct leaks caught:   #{length(direct_found)}")
    IO.puts("catch rate:            #{Float.round(catch_rate * 100, 1)}%")
    IO.puts("legit sink call sites: #{CorpusLabels.legit_sink_sites()}")
    IO.puts("false positives:       #{fp_count}")
    IO.puts("FP per 50 sites:       #{Float.round(fp_per_50, 2)}")
    IO.puts("laundered (exp. miss): #{CorpusLabels.laundered_count()}")

    assert catch_rate == 1.0
    assert fp_count == 0
    assert fp_per_50 < 1.0
  end
end
