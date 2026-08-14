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
    # authorize?: false, cannot green-light the gate. INDEPENDENTLY LOAD-BEARING
    # (verifier R1): a framework-only sweep (verticals dropped — the S15b regression)
    # measures 729 files / 130 governed / 45 sanctioned, so EACH floor below fails
    # that shape on its own, not only via the roll-call's path assertions.
    # (At the S15 hardening the full sweep saw 841 files / 150 governed reads.)
    assert files >= 800
    assert governed >= 140

    # The sanctioned reads are a KNOWN, per-site-justified set (S15 hardening: 49 —
    # pre-auth boot-path/unique-key lookups, webhook-ingest provider-ref lookups,
    # FK cascades, the system-plane sweeps, the operator activity rollup), each
    # carrying a `# authz-scope:` reason at the read site. A regression that started
    # silently swallowing violations as sanctions would blow this ceiling; a lost
    # marker (or a lost pin downgraded to a sanction) would move it. Lower bound 47:
    # ABOVE the framework-only count (45, so a dropped vertical sweep goes red here
    # too) while leaving headroom for two marker→genuine-pin conversions before a
    # conscious band update — shrinking the sanctioned set further than that is a
    # deliberate posture change and SHOULD re-open this test.
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
end
