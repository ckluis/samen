defmodule Samen.Gen.ProbeAbbrev do
  @moduledoc """
  Collision-checked, deterministic app-identity derivation for the three `ci.sh` gen probes
  (`priv/gen_post_probe.exs`, `priv/gen_app_flagship_probe.exs`,
  `priv/gen_app_deploy_probe.exs`).

  ## Why this exists (the determinism carry)

  Each probe generates a throwaway scratch app whose abbrevs are written into (and then
  restored from) the committed `priv/abbrev_registry.json`. The abbrevs used to be derived
  from `System.unique_integer/1` mapped onto the fixed `j*` prefix family, with a couple of
  **hand-remapped** known collisions (`jwh` vs the primitives Webhook abbrev, `jfl`/`jfk`
  vs billing). That is fragile *by construction*: the `j*` families
  (`primitives` → `jnt/jnp/jfl/jsh/jwh/jff`, `operator` → `jo*/jp*/jq*`) depend only on the
  first prefix letter, so the moment the committed registry grows a `j*`/`*wh`/`*z` abbrev,
  NO choice of the derived letters can avoid it and `Gen.reserve_abbrevs!/1` fails the probe
  — a non-deterministic `ci.sh` flake. It was hand-de-flaked twice; this module encodes the
  de-flake as infra.

  ## The guarantee

  `app_identity/4` derives a `{module, prefix, abbrev}` (plus an optional second
  `resource_abbrev`) whose **entire** derived reserved set — billing + aggregate + the
  authored resource + the web `Primitives`/`Operator` families — is checked against the
  loaded registry (`Samen.AbbrevRegistry.load/0`, the flattened global collision oracle)
  **and** is internally distinct, and it advances deterministically to the next candidate on
  any collision. Because the whole family (both prefix letters included) is searched — not a
  fixed `j*` space — it can NEVER collide with the committed registry regardless of how the
  registry grows. The search STARTS from a `seed`-derived candidate (so each run is fresh, a
  stale scratch dir never clashes) and advances in a fixed order, so it is
  collision-proof by construction, not by the "`j*` is unowned" assumption.

  The ultimate gate is unchanged: the probe still calls `Gen.validate!/1` (→
  `Gen.validate_against!/2`) and `Gen.reserve_abbrevs!/1`; this module only guarantees those
  never raise on a collision.
  """

  alias Samen.Gen.App

  @space 26 * 26 * 26

  @doc """
  Advance a candidate 3-letter-lowercase abbrev to the next abbrev NOT present in `taken`,
  scanning the 3-letter space in odometer order (last letter fastest, wrapping `zzz → aaa`).
  Returns the first clear abbrev — the candidate itself when it is already clear.

  `taken` is any enumerable of abbrev strings. Pure (no IO), total over the whole
  17,576-abbrev space, and raises only if EVERY abbrev is taken (impossible in practice —
  the registry is a few hundred entries). This is the testable core of the collision check.
  """
  @spec next_clear_abbrev(String.t(), Enumerable.t()) :: String.t()
  def next_clear_abbrev(<<_, _, _>> = candidate, taken) do
    taken_set = MapSet.new(taken)
    scan_clear(abbrev_to_int(candidate), taken_set, 0)
  end

  defp scan_clear(_i, _taken, tries) when tries >= @space do
    raise "Samen.Gen.ProbeAbbrev: the entire 3-letter abbrev space is exhausted — the " <>
            "committed registry cannot possibly own all 17,576 abbrevs."
  end

  defp scan_clear(i, taken, tries) do
    abbrev = int_to_abbrev(rem(i, @space))

    if MapSet.member?(taken, abbrev) do
      scan_clear(i + 1, taken, tries + 1)
    else
      abbrev
    end
  end

  @doc """
  Derive a collision-free generation identity for a probe app.

  Arguments:

    * `base` — the module-name stem (e.g. `"Genflag"`); the chosen prefix is appended
      upper-cased so distinct prefixes yield distinct module names (same shape the probes
      used before: `"Genflag" <> "KB"`).
    * `shape_opts` — the `build_spec/1` options that determine the derived family
      SHAPE (`:web`, `:api`, `:modules`, `:deploy`, `:port`, `:target`) — everything EXCEPT
      `:module`/`:prefix`/`:abbrev`, which this function supplies. `web: true` is what pulls
      in the Primitives/Operator families.
    * `registry` — the collision oracle, a `%{abbrev => owner}` map
      (`Samen.AbbrevRegistry.load/0`).
    * `seed` — an integer (a `System.unique_integer([:positive])`) that seeds the search
      START so each run is fresh; the search then advances deterministically.

  Options:

    * `:extra_resource?` (default `false`) — also derive a second, distinct `resource_abbrev`
      (for the post-app probe, which reserves a `gen.resource` abbrev on top of the app's
      own set).

  Returns `%{module: ..., prefix: ..., abbrev: ...}` (plus `:resource_abbrev` when
  `extra_resource?: true`). The returned identity is GUARANTEED to make
  `App.validate_against!/2` pass against `registry`: the whole derived reserved set is clear
  and internally distinct, and any extra `resource_abbrev` is clear of the registry, the
  family AND the app abbrev.
  """
  @spec app_identity(String.t(), keyword(), map(), integer(), keyword()) :: %{
          required(:module) => String.t(),
          required(:prefix) => String.t(),
          required(:abbrev) => String.t(),
          optional(:resource_abbrev) => String.t()
        }
  def app_identity(base, shape_opts, registry, seed, opts \\ [])
      when is_binary(base) and is_map(registry) and is_integer(seed) do
    extra_resource? = Keyword.get(opts, :extra_resource?, false)

    registry_keys = MapSet.new(Map.keys(registry))

    # 1. A prefix whose derived family (billing + aggregate + primitives + operator) is
    #    registry-clear AND internally distinct. Searched over the WHOLE 2-letter space
    #    starting at the seed, so no fixed-`j*` assumption survives.
    {prefix, family} = clear_prefix(base, shape_opts, registry_keys, seed)

    taken_family = MapSet.union(registry_keys, MapSet.new(family))

    # 2. The authored-resource abbrev: clear of the registry AND the prefix family.
    app_abbrev = next_clear_abbrev(int_to_abbrev(seed), taken_family)

    identity = %{
      module: base <> String.upcase(prefix),
      prefix: prefix,
      abbrev: app_abbrev
    }

    if extra_resource? do
      # 3. The second (gen.resource) abbrev: clear of the registry, the family AND the app
      #    abbrev — mutually distinct within this probe's in-flight set.
      taken_all = MapSet.put(taken_family, app_abbrev)
      resource_abbrev = next_clear_abbrev(int_to_abbrev(seed + 1), taken_all)
      Map.put(identity, :resource_abbrev, resource_abbrev)
    else
      identity
    end
  end

  # Scan the 2-letter prefix space (from the seed) for a prefix whose derived family is
  # registry-clear and internally distinct. Returns `{prefix, family_abbrevs}`.
  defp clear_prefix(base, shape_opts, registry_keys, seed) do
    start = rem(seed, 26 * 26)
    scan_prefix(base, shape_opts, registry_keys, start, 0)
  end

  defp scan_prefix(_base, _shape, _keys, _i, tries) when tries >= 26 * 26 do
    raise "Samen.Gen.ProbeAbbrev: no 2-letter prefix has a registry-clear derived family — " <>
            "the committed registry cannot possibly saturate all 676 prefix families."
  end

  defp scan_prefix(base, shape_opts, registry_keys, i, tries) do
    prefix = int_to_prefix(rem(i, 26 * 26))
    family = derived_family(base, shape_opts, prefix)

    internally_distinct? = family == Enum.uniq(family)
    registry_clear? = not Enum.any?(family, &MapSet.member?(registry_keys, &1))

    if internally_distinct? and registry_clear? do
      {prefix, family}
    else
      scan_prefix(base, shape_opts, registry_keys, i + 1, tries + 1)
    end
  end

  # The prefix-derived family = every reserved abbrev EXCEPT the authored resource's own
  # (identified by owner, robust to any prefix — never by value). Built through the SAME
  # `App.reserved_pairs/1` the reservation + validation use, so there is one source of truth.
  defp derived_family(base, shape_opts, prefix) do
    spec =
      shape_opts
      |> Keyword.put(:module, base)
      |> Keyword.put(:prefix, prefix)
      # Placeholder authored-resource abbrev; excluded from the family by owner below.
      |> Keyword.put(:abbrev, "zzz")
      |> App.build_spec()

    spec
    |> App.reserved_pairs()
    |> Enum.reject(fn {_abbrev, owner} -> owner == spec.resource_module end)
    |> Enum.map(&elem(&1, 0))
  end

  # --- deterministic base-26 codecs ------------------------------------------------------
  defp int_to_abbrev(n) do
    n = Integer.mod(n, @space)
    <<?a + div(n, 26 * 26), ?a + rem(div(n, 26), 26), ?a + rem(n, 26)>>
  end

  defp abbrev_to_int(<<a, b, c>>), do: (a - ?a) * 26 * 26 + (b - ?a) * 26 + (c - ?a)

  defp int_to_prefix(n) do
    n = Integer.mod(n, 26 * 26)
    <<?a + div(n, 26), ?a + rem(n, 26)>>
  end
end
