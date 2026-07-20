defmodule Samen.Gen.ProbeAbbrevTest do
  @moduledoc """
  Determinism GUARANTEE for the ci.sh gen-probe abbrev derivation (F7 unit 9).

  `Samen.Gen.ProbeAbbrev` replaces the three probes' fragile hand-remapped `j*`
  derivation with a deterministic, COLLISION-CHECKED one: the whole derived reserved
  family is checked against the registry and advanced on any collision, so the probes
  can NEVER fail `Gen.reserve_abbrevs!/1` on a collision no matter how the committed
  registry grows.

  These tests prove the collision check actually WORKS (advances past a taken candidate),
  not merely that it happens not to collide this run — the anti-tautology bar: the naive
  candidate IS taken, the chosen one is NOT, and the whole chosen family passes
  `Samen.Gen.App.validate_against!/2` (the same fail-closed oracle the probe's own
  `Gen.validate!/1` runs).
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App
  alias Samen.Gen.ProbeAbbrev

  @shape [web: true, api: true, target: "."]

  # ==========================================================================
  # next_clear_abbrev/2 — the testable core of the collision advance.
  # ==========================================================================

  test "next_clear_abbrev returns the candidate unchanged when it is already clear" do
    assert ProbeAbbrev.next_clear_abbrev("mmm", []) == "mmm"
    assert ProbeAbbrev.next_clear_abbrev("mmm", ["aaa", "zzz"]) == "mmm"
  end

  test "next_clear_abbrev advances past a taken run (anti-tautology: naive taken, chosen not)" do
    taken = ["mmm", "mmn", "mmo"]
    chosen = ProbeAbbrev.next_clear_abbrev("mmm", taken)

    # The naive candidate WAS taken; the chosen one is NOT — and it is the deterministic
    # next odometer step, not an arbitrary jump.
    assert "mmm" in taken
    refute chosen in taken
    assert chosen == "mmp"
  end

  test "next_clear_abbrev wraps zzz -> aaa deterministically" do
    assert ProbeAbbrev.next_clear_abbrev("zzz", ["zzz"]) == "aaa"
  end

  test "next_clear_abbrev result is always 3 lowercase letters and registry-clear" do
    taken = ~w(mmm mmn mmo mmp mmq)
    chosen = ProbeAbbrev.next_clear_abbrev("mmm", taken)
    assert Regex.match?(~r/\A[a-z]{3}\z/, chosen)
    refute chosen in taken
    assert chosen == "mmr"
  end

  # ==========================================================================
  # app_identity/5 — the whole derived family is registry-clear + distinct.
  # ==========================================================================

  test "app_identity yields an identity whose WHOLE reserved set passes validate_against!" do
    registry = sample_spec("aa", "aaa") |> App.reserved_pairs() |> Map.new()

    for seed <- [1, 2, 7, 42, 500, 12_345] do
      id = ProbeAbbrev.app_identity("Genprobe", @shape, registry, seed)
      spec = build(id)
      # The exact fail-closed oracle the probe's Gen.validate!/1 runs — must NOT raise.
      assert App.validate_against!(spec, registry) == :ok
    end
  end

  test "app_identity is deterministic: same seed + registry -> identical identity" do
    registry = %{}
    a = ProbeAbbrev.app_identity("Genprobe", @shape, registry, 4242)
    b = ProbeAbbrev.app_identity("Genprobe", @shape, registry, 4242)
    assert a == b
  end

  test "app_identity advances the app abbrev when the naive pick is already reserved (anti-tautology)" do
    seed = 31_337

    # First derivation against an EMPTY registry: this is the naive pick.
    naive = ProbeAbbrev.app_identity("Genprobe", @shape, %{}, seed)

    # Now make the naive app abbrev already-owned. Same seed MUST advance to a different,
    # registry-clear abbrev — proving the check is load-bearing, not incidental.
    registry = %{naive.abbrev => "Someone.Else.Resource"}
    advanced = ProbeAbbrev.app_identity("Genprobe", @shape, registry, seed)

    assert Map.has_key?(registry, naive.abbrev), "the naive candidate must be the taken one"
    refute Map.has_key?(registry, advanced.abbrev), "the chosen abbrev must be registry-clear"
    assert advanced.abbrev != naive.abbrev
    assert App.validate_against!(build(advanced), registry) == :ok
  end

  test "app_identity advances the PREFIX when a family member is already reserved (anti-tautology)" do
    seed = 99_991

    naive = ProbeAbbrev.app_identity("Genprobe", @shape, %{}, seed)
    naive_family = family_of(naive)

    # Reserve ONE member of the naive prefix's derived family to a foreign owner. The same
    # seed MUST move to a prefix whose whole family avoids it.
    victim = hd(naive_family)
    registry = %{victim => "Foreign.Owner"}
    advanced = ProbeAbbrev.app_identity("Genprobe", @shape, registry, seed)

    advanced_family = family_of(advanced)

    assert victim in naive_family, "the injected abbrev must belong to the naive family"
    refute victim in advanced_family, "the chosen prefix's family must avoid the reserved abbrev"
    assert advanced.prefix != naive.prefix
    assert App.validate_against!(build(advanced), registry) == :ok
  end

  test "app_identity with extra_resource? yields a mutually-distinct, clear second abbrev" do
    registry = sample_spec("bb", "bbb") |> App.reserved_pairs() |> Map.new()

    id = ProbeAbbrev.app_identity("Genprobe", @shape, registry, 24_601, extra_resource?: true)
    family = family_of(id)

    assert Map.has_key?(id, :resource_abbrev)
    refute Map.has_key?(registry, id.resource_abbrev), "resource abbrev must be registry-clear"
    refute id.resource_abbrev in family, "resource abbrev must be distinct from the app family"
    assert id.resource_abbrev != id.abbrev, "resource abbrev must differ from the app abbrev"
    assert App.validate_against!(build(id), registry) == :ok
  end

  # --- helpers ---------------------------------------------------------------------------
  defp sample_spec(prefix, abbrev) do
    App.build_spec(Keyword.merge(@shape, module: "Sample", prefix: prefix, abbrev: abbrev))
  end

  defp build(id) do
    App.build_spec(Keyword.merge(@shape, module: id.module, prefix: id.prefix, abbrev: id.abbrev))
  end

  # The prefix-derived family = every reserved abbrev except the authored resource's own.
  defp family_of(id) do
    spec = build(id)

    spec
    |> App.reserved_pairs()
    |> Enum.reject(fn {_ab, owner} -> owner == spec.resource_module end)
    |> Enum.map(&elem(&1, 0))
  end
end
