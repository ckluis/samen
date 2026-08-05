defmodule Samen.Web.Authz.ReadScopeLintTest do
  @moduledoc """
  The DEFENSE-IN-DEPTH `authorize?: false` read-scope lint (T132, companion to T127).

    * **GREEN (completeness)** — `ReadScopeLint.assert_all_scoped!/0` sweeps EVERY
      `.ex` under `samen_core/lib` + `samen_web/lib` and passes only if every direct
      `authorize?: false` read is pinned (org_id/id filter, by-id `Ash.get`, or a
      scalar aggregate) or carries a `# authz-scope:` sanction. New modules/reads are
      swept in automatically — an unpinned read cannot go green by not being named.
    * **Non-vacuity** — the sweep must see the whole two-app surface and a realistic
      number of governed reads; a glob/AST regression that matches nothing (or misses
      `authorize?: false`) cannot green-light the gate.
    * **RED (the T127 latent shape)** — a modeled bare `authorize?: false` read with NO
      narrowing is FLAGGED and `assert_all_scoped!` RAISES. Anti-tautology: the SAME
      fixture with a one-line `org_id` filter (or a by-id get, or an aggregate, or the
      sanction marker) PASSES — the lint discriminates, it is not a no-op.
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

  # ---------------------------------------------------------------------------
  # GREEN — completeness over the whole two-app surface
  # ---------------------------------------------------------------------------

  test "GREEN (T132): EVERY direct authorize?: false read across samen_core + samen_web is pinned or sanctioned" do
    assert {:ok, %{files: files, governed_reads: governed, sanctioned_reads: sanctioned}} =
             Lint.assert_all_scoped!()

    # Non-vacuity: the sweep saw both app trees (hundreds of modules) and a realistic
    # governed-read count — a matcher that finds none, or that misses authorize?: false,
    # cannot green-light the gate.
    assert files >= 300
    assert governed >= 80

    # The sanctioned org-less reads (retention sweep ×2, ingest/threading read_one, the
    # operator anchor) are a KNOWN, small set — each carries a `# authz-scope:` reason.
    # A regression that started silently swallowing violations as sanctions would blow
    # this ceiling; a lost marker would drop it.
    assert sanctioned in 4..8
  end

  test "COMPLETENESS ROLL-CALL: the sweep covers both kernels and skips the seed/fixture harnesses" do
    files = Lint.source_files()

    assert Enum.any?(files, &String.ends_with?(&1, "samen_core/lib/samen/operator_plane.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "samen_web/lib/samen/web/operator/reads.ex"))

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

  test "a read WITHOUT authorize?: false is NOT governed by this lint (OrgScope stays on)" do
    {violations, governed, sanctioned} =
      Lint.scan_source(@scoped_on_fixture, "fixture/scoped_on_read.ex")

    assert violations == []
    assert governed == 0
    assert sanctioned == 0
  end
end
