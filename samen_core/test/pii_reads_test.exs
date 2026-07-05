defmodule Samen.PiiReadsTest do
  @moduledoc """
  Production C3 `pii_reads` verifier (T1.8b) — the S0.7 acceptance on the real
  codebase PLUS the Gate-0 fix task #6 red paths:

    * direct leaks fail (green-path catch on the real registry);
    * the `reveal_`-prefixed NON-reveal function leaking now FAILS (the closed
      lexical-prefix evasion);
    * an `action :name` that was never declared `reveal :name` leaking FAILS;
    * an aliased-Logger (`alias Logger, as: L`) leak FAILS;
    * a genuinely-DECLARED `reveal :action` site is suppressed (clean, exit 0);
    * declaration sites (`pii do … end`) are never flagged;
    * laundered leaks are documented expected-misses (advisory hint, exit 0);
    * fail-closed exit codes; parse errors fail closed.

  The registry is built from REAL `Samen.Pii.Info` introspection over the fixture
  resources (Gate-0 fix #6 (c)), never a hand seed set.
  """
  use ExUnit.Case, async: true

  alias Samen.PiiReads
  alias Samen.PiiReads.{Harness, Registry}
  alias SamenCore.Support.PiiReadsCorpusLabels, as: Labels

  @reg Labels.registry()

  @leaks_dir Labels.path("leaks")
  @clean_dir Labels.path("clean")
  @laundered_dir Labels.path("laundered")

  defp scan!(dir), do: elem(PiiReads.scan_dir(dir, @reg), 1)
  defp direct(findings), do: Enum.filter(findings, &(&1.kind == :direct_leak))
  defp hints(findings), do: Enum.filter(findings, &(&1.kind == :laundered_hint))

  # ---------------------------------------------------------------------------
  # The registry is REAL introspection (Gate-0 fix #6 c)
  # ---------------------------------------------------------------------------

  test "registry PII set is derived from Samen.Pii.Info over the fixtures' pii do blocks" do
    # Logical names AND storage names, both counted as tainted sources.
    for name <- [:full_name, :emails, :dob, :mrn, :phones],
        do: assert(Registry.pii_attribute?(@reg, name))

    for name <- [:pat_full_name, :pat_emails, :pat_phones, :pii_pat_dob, :pii_pat_mrn, :rvp_emails],
        do: assert(Registry.pii_attribute?(@reg, name))

    # A non-PII column is NOT in the set.
    refute Registry.pii_attribute?(@reg, :pat_org_id)
    refute Registry.pii_attribute?(@reg, :status)
  end

  test "registry reveal actions come from the first-class reveal :action marker" do
    person = SamenCore.Support.RevealDomain.RevealPerson

    # The DECLARED reveal action.
    assert Registry.reveal_action?(@reg, person, :reveal_email)

    # The trap: an action whose NAME contains "reveal" but was NOT declared.
    refute Registry.reveal_action?(@reg, person, :read_email_looks_like_reveal)

    # A `reveal`-prefixed name on a NON-resource module is never a reveal action.
    refute Registry.reveal_action?(@reg, SomeRandomModule, :reveal_report)
    refute Registry.reveal_action?(@reg, nil, :reveal_report)
  end

  # ---------------------------------------------------------------------------
  # GREEN PATH — catches ALL direct leaks (incl. the closed evasions)
  # ---------------------------------------------------------------------------

  test "catches every seeded direct leak (catch rate = 100%), including the closed evasions" do
    found = @leaks_dir |> scan!() |> direct()
    assert length(found) == Labels.direct_leak_count()

    for {rel, line, pii} <- Labels.direct_leaks() do
      match =
        Enum.find(found, fn f -> String.ends_with?(f.file, rel) and f.line == line end)

      assert match, "missed seeded direct leak at #{rel}:#{line}"
      assert Enum.sort(match.pii) == Enum.sort(pii)
    end
  end

  test "every leak-file finding is scoped :out_of_reveal" do
    for f <- @leaks_dir |> scan!() |> direct(), do: assert(f.scope == :out_of_reveal)
  end

  test "RED PATH: the leak corpus makes the harness fail closed (exit 1)" do
    {code, _} = Harness.check_dirs([@leaks_dir], @reg)
    assert code == 1
  end

  # ---------------------------------------------------------------------------
  # Gate-0 fix #6 (a): reveal-scope keys on the REAL action, not a name prefix
  # ---------------------------------------------------------------------------

  test "RED PATH: a reveal_-prefixed NON-reveal function leaking is now CAUGHT (closed evasion)" do
    # This is the exact S0.7 caveat #1 evasion. The spike's lexical prefix
    # suppressed ALL sinks in any reveal*-named fn → zero findings. Production C3
    # keys on the real reveal :action marker, so a bare `def reveal_report` is NOT
    # a reveal boundary and this MUST fail.
    src = ~S'''
    defmodule Bad do
      require Logger
      def reveal_report(patient) do
        Logger.info("ssn=#{patient.pii_pat_dob}")
      end
    end
    '''

    findings = PiiReads.scan_source("bad.ex", src, @reg)
    assert length(direct(findings)) == 1, "reveal_-prefixed non-reveal leak must be caught"
    assert hd(direct(findings)).pii == [:pii_pat_dob]

    {code, _} = Harness.check_sources([{"bad.ex", src}], @reg)
    assert code == 1
  end

  test "an `action :name` never declared `reveal :name` does NOT suppress its sinks" do
    # `action :reveal_report do … end` on a module that never declared
    # `reveal :reveal_report` — the registry says false, the sink is flagged.
    src = ~S'''
    defmodule NotAResource do
      require Logger
      action :reveal_report do
        Logger.error("leaked=#{subject.pii_pat_dob}")
      end
    end
    '''

    findings = PiiReads.scan_source("nr.ex", src, @reg)
    assert length(direct(findings)) == 1
  end

  test "a genuinely DECLARED reveal :action DOES suppress its sink (clean side)" do
    # The module IS the real RevealPerson resource, which declares
    # `reveal :reveal_email`. A sink inside `action :reveal_email` is allowed.
    src = ~S'''
    defmodule SamenCore.Support.RevealDomain.RevealPerson do
      require Logger
      action :reveal_email do
        Logger.info("revealed=#{subject.emails}")
      end
    end
    '''

    assert PiiReads.scan_source("rp.ex", src, @reg) == []
  end

  test "the EXACT on-disk Ash shape `action :name, :return_type do` is handled" do
    # A generic Ash action declares a return type: `action :reveal_email, :string
    # do … end`. The AST is {:action, _, [:reveal_email, :string, [do: …]]}. The
    # walker keys on the leading action-name atom regardless of trailing args.
    declared = ~S'''
    defmodule SamenCore.Support.RevealDomain.RevealPerson do
      require Logger
      action :reveal_email, :string do
        Logger.info("e=#{s.emails}")
      end
    end
    '''

    undeclared = ~S'''
    defmodule SamenCore.Support.RevealDomain.RevealPerson do
      require Logger
      action :read_email_looks_like_reveal, :string do
        Logger.info("e=#{s.emails}")
      end
    end
    '''

    assert PiiReads.scan_source("d.ex", declared, @reg) == []
    assert length(direct(PiiReads.scan_source("u.ex", undeclared, @reg))) == 1
  end

  test "the SAME sink is flagged in a non-reveal action but suppressed in the declared reveal action" do
    # Both modules ARE the real RevealPerson resource. The ONLY difference is the
    # action name: `:reveal_email` is a declared reveal action, so the identical
    # sink is suppressed; `:read_email_looks_like_reveal` is NOT declared (its
    # name merely contains "reveal"), so the identical sink is flagged.
    suppressed = ~S'''
    defmodule SamenCore.Support.RevealDomain.RevealPerson do
      require Logger
      action :reveal_email do
        Logger.info("e=#{s.emails}")
      end
    end
    '''

    flagged = ~S'''
    defmodule SamenCore.Support.RevealDomain.RevealPerson do
      require Logger
      action :read_email_looks_like_reveal do
        Logger.info("e=#{s.emails}")
      end
    end
    '''

    assert PiiReads.scan_source("s.ex", suppressed, @reg) == [],
           "declared reveal action must suppress"

    flagged_findings = PiiReads.scan_source("f.ex", flagged, @reg)

    assert length(direct(flagged_findings)) == 1,
           "an undeclared (name-looks-like-reveal) action must NOT suppress"
  end

  # ---------------------------------------------------------------------------
  # Gate-0 fix #6 (b): aliased sink modules are resolved
  # ---------------------------------------------------------------------------

  test "RED PATH: an aliased-Logger leak (alias Logger, as: L) is CAUGHT" do
    src = ~S'''
    defmodule Aliased do
      alias Logger, as: L
      def go(p), do: L.info("name=#{p.full_name}")
    end
    '''

    findings = PiiReads.scan_source("al.ex", src, @reg)
    assert length(direct(findings)) == 1, "aliased Logger leak must be caught"
    assert hd(direct(findings)).sink == "Logger.info"
  end

  test "an aliased OTel span module leak is CAUGHT" do
    src = ~S'''
    defmodule AliasedSpan do
      alias OpenTelemetry.Span, as: S
      def trace(span, p), do: S.set_attribute(span, "mrn", p.mrn)
    end
    '''

    findings = PiiReads.scan_source("as.ex", src, @reg)
    assert length(direct(findings)) == 1
    assert hd(direct(findings)).sink == "OpenTelemetry.Span.set_attribute"
  end

  test "an aliased Logger carrying a NON-pii token does not false-positive" do
    src = ~S'''
    defmodule AliasClean do
      alias Logger, as: L
      def go(ctx), do: L.info("id=#{ctx.request_id}")
    end
    '''

    assert PiiReads.scan_source("ac.ex", src, @reg) == []
  end

  # ---------------------------------------------------------------------------
  # ZERO false positives on the clean corpus (acceptance criterion)
  # ---------------------------------------------------------------------------

  test "zero false positives on the clean corpus (declarations + declared reveal + non-pii)" do
    found = scan!(@clean_dir)
    assert found == [], "false positives: #{inspect(found)}"
  end

  test "the clean corpus exits 0 (RED PATH clean side)" do
    {code, _} = Harness.check_dirs([@clean_dir], @reg)
    assert code == 0
  end

  test "pii_attribute declaration sites are NOT flagged (declaration ≠ flow)" do
    # A `pii do … end` block names pii fields but is a declaration. A grep for
    # the pii names flags it; the AST walker must not.
    src = ~S'''
    defmodule R do
      use Samen.Resource
      pii do
        pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
        pii_attribute(:dob, :date, vault: :pii_dob)
      end
    end
    '''

    assert PiiReads.scan_source("decl.ex", src, @reg) == []
  end

  # ---------------------------------------------------------------------------
  # LAUNDERED leaks — documented EXPECTED MISSES + advisory hint (Gate-0 fix #6 d)
  # ---------------------------------------------------------------------------

  test "laundered leaks are missed by the AST layer (expected, by design) — exit 0" do
    found = scan!(@laundered_dir)

    assert direct(found) == [],
           "laundered leaks were flagged as direct — the honest expected-miss boundary changed"

    {code, _} = Harness.check_dirs([@laundered_dir], @reg)
    assert code == 0, "laundered hints must NOT affect the exit code (J2 is Phase 2)"
  end

  test "a cheaply-detectable helper hop emits a :laundered_hint citing J2 (advisory only)" do
    found = scan!(@laundered_dir)
    hs = hints(found)

    assert length(hs) == Labels.laundered_count()
    assert Enum.all?(hs, &(&1.note =~ "J2"))
    # A hint never contributes to the failing set.
    assert Harness.failing(found) == []
  end

  # ---------------------------------------------------------------------------
  # Fail-closed on unparseable source (does not silently skip)
  # ---------------------------------------------------------------------------

  test "unparseable source is a parse_error finding (fail closed, exit 1)" do
    {code, findings} = Harness.check_sources([{"broken.ex", "defmodule X do def"}], @reg)
    assert code == 1
    assert Enum.any?(findings, &(&1.kind == :parse_error))
  end

  # ---------------------------------------------------------------------------
  # RED PATH meta-check — the exit code is a FUNCTION of the pii presence
  # ---------------------------------------------------------------------------

  test "RED PATH meta-check: identical structure, one has pii, one does not" do
    with_pii = ~S'''
    defmodule A do
      require Logger
      def f(x), do: Logger.info("#{x.full_name}")
    end
    '''

    without_pii = ~S'''
    defmodule A do
      require Logger
      def f(x), do: Logger.info("#{x.request_id}")
    end
    '''

    {c1, _} = Harness.check_sources([{"a.ex", with_pii}], @reg)
    {c2, _} = Harness.check_sources([{"a.ex", without_pii}], @reg)

    assert c1 == 1
    assert c2 == 0
    refute c1 == c2, "the exit code must be a function of the pii presence"
  end

  # ---------------------------------------------------------------------------
  # Metrics (catch rate / false-positive rate) — plan S0.7 findings
  # ---------------------------------------------------------------------------

  test "reports catch rate and false-positive rate numerically" do
    direct_found = @leaks_dir |> scan!() |> direct()
    fp_found = scan!(@clean_dir)

    catch_rate = length(direct_found) / Labels.direct_leak_count()
    fp_count = length(fp_found)
    fp_per_50 = fp_count / Labels.legit_sink_sites() * 50

    IO.puts("\n--- pii_reads (prod C3) metrics ---")
    IO.puts("direct leaks seeded:   #{Labels.direct_leak_count()}")
    IO.puts("direct leaks caught:   #{length(direct_found)}")
    IO.puts("catch rate:            #{Float.round(catch_rate * 100, 1)}%")
    IO.puts("legit sink call sites: #{Labels.legit_sink_sites()}")
    IO.puts("false positives:       #{fp_count}")
    IO.puts("FP per 50 sites:       #{Float.round(fp_per_50, 2)}")
    IO.puts("laundered (exp. miss): #{Labels.laundered_count()}")

    assert catch_rate == 1.0
    assert fp_count == 0
    assert fp_per_50 < 1.0
  end
end
