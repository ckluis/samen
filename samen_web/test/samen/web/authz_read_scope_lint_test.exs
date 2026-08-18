defmodule Samen.Web.Authz.ReadScopeLintTest do
  @moduledoc """
  The DEFENSE-IN-DEPTH `authorize?: false` read-scope lint (T132, companion to T127;
  strengthened + widened for luminary S15).

    * **GREEN (completeness)** — `ReadScopeLint.assert_all_scoped!/0` sweeps EVERY
      `.ex` under `samen_core/lib` + `samen_web/lib` + the three vertical trees
      (`demo/lib`, `driftwood/lib`, `pawchart/lib` — the S15 sweep extension) and
      passes only if every direct `authorize?: false` read is pinned (a genuine
      org_id/id SCOPING filter, a by-id `Ash.get`, or a scalar aggregate) or carries
      a justified `# authz-scope:` sanction. New modules/reads are swept in
      automatically — an unpinned read cannot go green by not being named.
    * **Non-vacuity** — the sweep must see the whole five-tree surface and a realistic
      number of governed reads; a glob/AST regression that matches nothing (or misses
      `authorize?: false`) cannot green-light the gate.
    * **RED (the T127 latent shape)** — a modeled bare `authorize?: false` read with NO
      narrowing is FLAGGED and `assert_all_scoped!` RAISES. Anti-tautology: the SAME
      fixture with a one-line `org_id` filter (or a by-id get, or an aggregate, or the
      sanction marker) PASSES — the lint discriminates, it is not a no-op.
    * **RED (the S15 select-forcing decoy)** — `Ash.Query.ensure_selected([:org_id])`
      forces `org_id` into the SELECT and scopes NOTHING; the pre-S15 lint counted it
      as a pin. It is now FLAGGED, as is a filter on some non-org/non-PK field alone —
      only a narrowing call whose own args carry the `org_id`/`id` pin counts.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Authz.ReadScopeLint, as: Lint
  alias Samen.Web.Authz.UnscopedReadError

  # The EXACT T127 latent shape: a direct authorize?: false read with NO org filter —
  # OrgScope OFF, returns every org's rows.
  @unpinned_fixture """
  defmodule Samen.Web.Fixture.UnpinnedRead do
    require Ash.Query

    def all(resource) do
      resource
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)
    end
  end
  """

  # The SAME read, one-line org_id pin applied.
  @pinned_fixture """
  defmodule Samen.Web.Fixture.PinnedRead do
    require Ash.Query

    def all(resource, org_id) do
      resource
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)
    end
  end
  """

  @by_id_fixture """
  defmodule Samen.Web.Fixture.ByIdRead do
    def one(resource, id) do
      Ash.get!(resource, id, authorize?: false)
    end
  end
  """

  @aggregate_fixture """
  defmodule Samen.Web.Fixture.AggregateRead do
    require Ash.Query

    def how_many(resource) do
      Ash.count!(resource, authorize?: false)
    end
  end
  """

  # A deliberately org-less read, sanctioned with the greppable marker.
  @sanctioned_fixture """
  defmodule Samen.Web.Fixture.SanctionedRead do
    require Ash.Query

    def anchor(resource) do
      resource
      |> Ash.Query.limit(1)
      # authz-scope: singleton anchor bootstrap — discovers the org id, cannot be pinned
      |> Ash.read!(authorize?: false)
    end
  end
  """

  # A read that does NOT pass authorize?: false — it is NOT a governed read and must be
  # invisible to this lint (it runs OrgScope on).
  @scoped_on_fixture """
  defmodule Samen.Web.Fixture.ScopedOnRead do
    require Ash.Query

    def all(resource, scope) do
      resource
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(scope: scope)
    end
  end
  """

  # The EXACT S15 decoy: `ensure_selected([:org_id])` is select-FORCING, not scoping —
  # this read still returns EVERY org's rows (org_id merely rides along in the SELECT).
  # The pre-S15 lint counted it as an org pin; it must be FLAGGED.
  @ensure_selected_decoy_fixture """
  defmodule Samen.Web.Fixture.EnsureSelectedDecoy do
    require Ash.Query

    def all_orgs(resource) do
      resource
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)
    end
  end
  """

  # A filter on some OTHER field alone — narrowing-ish, but the lint cannot prove a
  # non-org/non-PK predicate bounds the read to one tenant, so it demands the sanction
  # marker instead of passing silently.
  @non_org_filter_fixture """
  defmodule Samen.Web.Fixture.NonOrgFilterRead do
    require Ash.Query

    def active(resource) do
      resource
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(authorize?: false)
    end
  end
  """

  # The `filter_input` string-key form of the same pin (`%{"org_id" => …}` /
  # `%{"id" => …}`) — a genuine scoping filter, input-typed. PASSES.
  @filter_input_pin_fixture """
  defmodule Samen.Web.Fixture.FilterInputPin do
    require Ash.Query

    def one(resource, id) do
      resource
      |> Ash.Query.filter_input(%{"id" => id})
      |> Ash.read_one(authorize?: false)
    end
  end
  """

  # ---------------------------------------------------------------------------
  # GREEN — completeness over the whole two-app surface
  # ---------------------------------------------------------------------------

  test "GREEN (T132/S15): EVERY direct authorize?: false read across all five trees is pinned or sanctioned" do
    assert {:ok, %{files: files, governed_reads: governed, sanctioned_reads: sanctioned}} =
             Lint.assert_all_scoped!()

    # Non-vacuity: the sweep saw all five app trees (hundreds of modules) and a
    # realistic governed-read count — a matcher that finds none, or that misses
    # authorize?: false, cannot green-light the gate. The FILES floor is INDEPENDENTLY
    # LOAD-BEARING against the S15b dropped-vertical regression: a framework-only sweep
    # (verticals dropped) measures 754 files < 800 on its own (the roll-call test below
    # independently asserts vertical coverage too). The governed/sanctioned floors guard
    # a DIFFERENT failure — a broken matcher that finds nothing or misses authorize?:
    # false collapses both toward 0; the kernel has since grown past the point where
    # they'd independently catch a dropped-vertical sweep (framework-only now measures
    # 154 governed / 48 sanctioned), so that shape is caught by the files floor + roll-call.
    # (Full sweep at the R3/R4/R5 addendum: 866 files / 174 governed / 52 sanctioned —
    # was 841 / 150 / 49 at S15; R4 surfaced 3 opts-smuggled reads + R3 re-sanctioned 3
    # clause-laundered reads with their own markers.)
    assert files >= 800
    assert governed >= 140

    # The sanctioned reads are a KNOWN, per-site-justified set (now 52 — pre-auth
    # boot-path/unique-key lookups, webhook-ingest provider-ref lookups, FK cascades,
    # the system-plane sweeps, the operator activity rollup, and the R3/R4 addendum's
    # three authorization-boundary reads: the two session-cap credential enumerations
    # and the mcp generic read helper — each carrying a `# authz-scope:` reason at the
    # read SITE, bound to exactly that read). A regression that started silently
    # swallowing violations as sanctions would blow this ceiling; a lost marker (or a
    # lost pin downgraded to a sanction) would move it. Lower bound 47 leaves headroom
    # for a couple marker→genuine-pin conversions before a conscious band update —
    # shrinking the sanctioned set further is a deliberate posture change and SHOULD
    # re-open this test. (At S15 this set was 49; the R3/R4 addendum added 3.)
    assert sanctioned in 47..60
  end

  test "COMPLETENESS ROLL-CALL: the sweep covers both kernels AND the vertical trees, and skips the seed/fixture harnesses" do
    files = Lint.source_files()

    assert Enum.any?(files, &String.ends_with?(&1, "samen_core/lib/samen/operator_plane.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "samen_web/lib/samen/web/operator/reads.ex"))

    # S15 sweep extension: the vertical trees are IN — they carried ~150
    # authorize?: false sites no lint ever swept.
    assert Enum.any?(files, &String.ends_with?(&1, "demo/lib/demo_web/api/key_auth_plug.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "driftwood/lib/driftwood_web/api/key_auth_plug.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "pawchart/lib/pawchart/auth.ex"))

    # Seed/fixture harnesses (system-actor reads at setup, no tenant surface) are OUT.
    refute Enum.any?(files, &String.ends_with?(&1, "/factory.ex"))
    refute Enum.any?(files, &String.ends_with?(&1, "/red_path.ex"))
  end

  # ---------------------------------------------------------------------------
  # RED — the lint discriminates (anti-tautology)
  # ---------------------------------------------------------------------------

  test "RED PATH (T127 latent shape): a bare unpinned authorize?: false read is FLAGGED with fun + line" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@unpinned_fixture, "fixture/unpinned_read.ex")

    assert governed == 1
    assert sanctioned == 0
    assert [%{fun: :all, arity: 1, file: "fixture/unpinned_read.ex", read_line: line}] = violations
    assert is_integer(line) and line > 0
  end

  test "RED PATH: assert_all_scoped! RAISES loudly over an unpinned read file — never a silent green" do
    dir = Path.join(System.tmp_dir!(), "samen_authz_lint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "unpinned.ex")
    File.write!(file, @unpinned_fixture)

    try do
      err = assert_raise UnscopedReadError, fn -> Lint.assert_all_scoped!([file]) end
      assert err.message =~ "UNSCOPED"
      assert err.message =~ "all/1"
    after
      File.rm_rf!(dir)
    end
  end

  test "ANTI-TAUTOLOGY: the SAME read with a one-line org_id filter PASSES — the pin is what flips it" do
    {violations, governed, _} = Lint.scan_source(@pinned_fixture, "fixture/pinned_read.ex")
    assert violations == []
    assert governed == 1
  end

  test "by-id Ash.get! is PINNED by construction (single row, id is an argument)" do
    {violations, governed, _} = Lint.scan_source(@by_id_fixture, "fixture/by_id_read.ex")
    assert violations == []
    assert governed == 1
  end

  test "a scalar aggregate (Ash.count!) is PINNED by construction (no cross-tenant row set)" do
    {violations, governed, _} = Lint.scan_source(@aggregate_fixture, "fixture/aggregate_read.ex")
    assert violations == []
    assert governed == 1
  end

  test "SANCTION: a deliberately org-less read with a # authz-scope: marker PASSES and is COUNTED (auditable, not silent)" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@sanctioned_fixture, "fixture/sanctioned_read.ex")

    assert violations == []
    assert governed == 1
    assert sanctioned == 1

    # And WITHOUT the marker the identical read is flagged — the marker is load-bearing,
    # not decoration.
    unmarked = String.replace(@sanctioned_fixture, ~r/\n.*authz-scope.*\n/, "\n")
    {violations2, _, sanctioned2} = Lint.scan_source(unmarked, "fixture/unmarked_read.ex")
    assert [%{fun: :anchor}] = violations2
    assert sanctioned2 == 0
  end

  test "RED PATH (S15): ensure_selected([:org_id]) is select-forcing, NOT scoping — the decoy is FLAGGED" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@ensure_selected_decoy_fixture, "fixture/ensure_selected_decoy.ex")

    assert governed == 1
    assert sanctioned == 0
    assert [%{fun: :all_orgs, arity: 1}] = violations

    # Anti-tautology: the SAME read with a genuine org_id FILTER passes — it is the
    # scoping construct that flips the verdict, not the org_id mention.
    repinned =
      String.replace(
        @ensure_selected_decoy_fixture,
        "def all_orgs(resource) do",
        "def all_orgs(resource, org_id) do"
      )
      |> String.replace(
        "|> Ash.Query.ensure_selected([:org_id])",
        "|> Ash.Query.ensure_selected([:org_id])\n    |> Ash.Query.filter(org_id == ^org_id)"
      )

    {violations2, governed2, _} = Lint.scan_source(repinned, "fixture/repinned_decoy.ex")
    assert violations2 == []
    assert governed2 == 1
  end

  test "RED PATH (S15): a filter on a non-org/non-PK field alone is FLAGGED — it needs the sanction marker" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@non_org_filter_fixture, "fixture/non_org_filter.ex")

    assert governed == 1
    assert sanctioned == 0
    assert [%{fun: :active, arity: 1}] = violations
  end

  test "filter_input with the string \"id\"/\"org_id\" pin key is a genuine scoping filter — PASSES" do
    {violations, governed, _} =
      Lint.scan_source(@filter_input_pin_fixture, "fixture/filter_input_pin.ex")

    assert violations == []
    assert governed == 1
  end

  test "a read WITHOUT authorize?: false is NOT governed by this lint (OrgScope stays on)" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@scoped_on_fixture, "fixture/scoped_on_read.ex")

    assert violations == []
    assert governed == 0
    assert sanctioned == 0
  end

  # ---------------------------------------------------------------------------
  # R3 — a pin/marker justifies EXACTLY its own read, not a clause sibling
  # (Phase-4 addendum: "the most plausible future laundering path")
  # ---------------------------------------------------------------------------

  # ONE `# authz-scope:` marker over TWO org-less reads. The marker binds to the FIRST
  # read; the SECOND is still unjustified and must be FLAGGED — the clause-scoped launder.
  @marker_launder_fixture """
  defmodule Samen.Web.Fixture.MarkerLaunder do
    require Ash.Query

    def two(a, b) do
      # authz-scope: system sweep — org-less by design
      first = Ash.read!(a, authorize?: false)
      second = Ash.read!(b, authorize?: false)
      {first, second}
    end
  end
  """

  # A clause holding a genuinely PINNED read AND a bare unpinned sibling. The sibling's
  # pin belongs to the OTHER read — it must not launder past a clause-level pin check.
  @pin_launder_fixture """
  defmodule Samen.Web.Fixture.PinLaunder do
    require Ash.Query

    def two(resource, org_id) do
      scoped =
        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read!(authorize?: false)

      everyone = Ash.read!(resource, authorize?: false)
      {scoped, everyone}
    end
  end
  """

  test "R3 (marker granularity): one # authz-scope: marker sanctions ONE read — a second org-less sibling is FLAGGED" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@marker_launder_fixture, "fixture/marker_launder.ex")

    assert governed == 2
    assert sanctioned == 1
    assert [%{fun: :two, arity: 2, read_line: flagged_line}] = violations

    # The flagged read is the SECOND one — the marker bound to the first.
    lines = String.split(@marker_launder_fixture, "\n")
    second_line = Enum.find_index(lines, &String.contains?(&1, "second =")) + 1
    assert flagged_line == second_line

    # Anti-tautology: give the second read its OWN marker and BOTH pass (two sanctions).
    two_markers =
      String.replace(
        @marker_launder_fixture,
        "    second = Ash.read!(b, authorize?: false)",
        "    # authz-scope: system sweep — org-less by design\n    second = Ash.read!(b, authorize?: false)"
      )

    {v2, g2, s2} = Lint.scan_source(two_markers, "fixture/two_markers.ex")
    assert v2 == []
    assert g2 == 2
    assert s2 == 2
  end

  test "R3 (pin granularity): a filter on a SIBLING read does NOT launder a bare unpinned read in the same clause" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@pin_launder_fixture, "fixture/pin_launder.ex")

    assert governed == 2
    assert sanctioned == 0
    # Only the unpinned `everyone` read is flagged — `scoped` is pinned by its own chain.
    assert [%{fun: :two, arity: 2, read_line: flagged_line}] = violations

    lines = String.split(@pin_launder_fixture, "\n")
    everyone_line = Enum.find_index(lines, &String.contains?(&1, "everyone =")) + 1
    assert flagged_line == everyone_line

    # Anti-tautology: pin `everyone` too (its OWN chain) and the clause passes clean.
    both_pinned = """
    defmodule Samen.Web.Fixture.BothPinned do
      require Ash.Query

      def two(resource, org_id) do
        scoped =
          resource
          |> Ash.Query.filter(org_id == ^org_id)
          |> Ash.read!(authorize?: false)

        everyone =
          resource
          |> Ash.Query.filter(org_id == ^org_id)
          |> Ash.read!(authorize?: false)

        {scoped, everyone}
      end
    end
    """

    {v2, g2, _s2} = Lint.scan_source(both_pinned, "fixture/both_pinned.ex")
    assert v2 == []
    assert g2 == 2
  end

  test "R3 (cross-statement pin): a read on a variable whose binding carries an org filter PASSES (no false positive)" do
    # `q = Resource |> filter(org_id == ^o); Ash.read(q, authorize?: false)` — the pin is
    # on a prior statement; the dataflow credits it to the variable, so this is NOT flagged.
    fixture = """
    defmodule Samen.Web.Fixture.CrossStatementPin do
      require Ash.Query

      def all(resource, org_id) do
        query =
          resource
          |> Ash.Query.filter(org_id == ^org_id)

        Ash.read!(query, authorize?: false)
      end
    end
    """

    {violations, governed, _} = Lint.scan_source(fixture, "fixture/cross_statement_pin.ex")
    assert violations == []
    assert governed == 1
  end

  # ---------------------------------------------------------------------------
  # R4 — opts-variable smuggling (authorize?: false hidden behind a name)
  # ---------------------------------------------------------------------------

  @opts_smuggle_fixture """
  defmodule Samen.Web.Fixture.OptsSmuggle do
    require Ash.Query

    def all(resource) do
      opts = [authorize?: false]
      Ash.read!(resource, opts)
    end
  end
  """

  test "R4 (opts smuggle): a read whose authorize?: false is smuggled via a local opts var is SEEN and FLAGGED" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@opts_smuggle_fixture, "fixture/opts_smuggle.ex")

    # It is GOVERNED (no longer invisible) and, being unpinned, FLAGGED.
    assert governed == 1
    assert sanctioned == 0
    assert [%{fun: :all, arity: 1}] = violations

    # Positive control: the SAME smuggled read, org-pinned in its chain, PASSES — proving
    # the read is seen and the pin (not the opts hiding) is what flips it.
    pinned =
      String.replace(
        @opts_smuggle_fixture,
        "    Ash.read!(resource, opts)",
        "    resource |> Ash.Query.filter(org_id == ^org_id) |> Ash.read!(opts)"
      )
      |> String.replace("def all(resource) do", "def all(resource, org_id) do")

    {v2, g2, _} = Lint.scan_source(pinned, "fixture/opts_smuggle_pinned.ex")
    assert v2 == []
    assert g2 == 1
  end

  test "R4 (specificity): an opts var that does NOT carry authorize?: false is NOT governed (no false positive)" do
    fixture = """
    defmodule Samen.Web.Fixture.NonAuthzOpts do
      require Ash.Query

      def all(resource) do
        opts = [domain: :crm]
        Ash.read!(resource, opts)
      end
    end
    """

    {violations, governed, sanctioned} = Lint.scan_source(fixture, "fixture/non_authz_opts.ex")
    assert violations == []
    assert governed == 0
    assert sanctioned == 0
  end

  # ---------------------------------------------------------------------------
  # R5 — non-Ash read wrappers (a read verb routed through another module)
  # ---------------------------------------------------------------------------

  @wrapper_bypass_fixture """
  defmodule Samen.Web.Fixture.WrapperBypass do
    def all(resource) do
      ScopedReads.read!(resource, authorize?: false)
    end
  end
  """

  test "R5 (wrapper bypass): a read verb on a NON-Ash module is governed too — an unpinned one is FLAGGED" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@wrapper_bypass_fixture, "fixture/wrapper_bypass.ex")

    assert governed == 1
    assert sanctioned == 0
    assert [%{fun: :all, arity: 1}] = violations

    # Anti-tautology: the same wrapper read, org-pinned in its chain, PASSES.
    pinned = """
    defmodule Samen.Web.Fixture.WrapperBypassPinned do
      require Ash.Query

      def all(resource, org_id) do
        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> ScopedReads.read!(authorize?: false)
      end
    end
    """

    {v2, g2, _} = Lint.scan_source(pinned, "fixture/wrapper_bypass_pinned.ex")
    assert v2 == []
    assert g2 == 1
  end

  test "R5 (bound): a wrapper whose NAME is not a read verb is NOT governed — the documented residual" do
    # `Reads.page!/3` is un-static-analyzable from the call site; it is closed
    # STRUCTURALLY instead (T127: page!/3 RAISES on authorize?: false), so the lint does
    # not — and cannot soundly — flag the call site. Documents the boundary of R5.
    fixture = """
    defmodule Samen.Web.Fixture.NonReadVerbWrapper do
      def all(resource) do
        Reads.page!(resource, authorize?: false)
      end
    end
    """

    {violations, governed, _} = Lint.scan_source(fixture, "fixture/non_read_verb_wrapper.ex")
    assert violations == []
    assert governed == 0
  end
end
