defmodule Samen.Web.LabelKeysCompletenessTest do
  @moduledoc """
  Structural, source-grep completeness check for `Samen.Web.Mount.@label_keys` (luminary A4).

  UNLIKE `marketing_session_roundtrip_test.exs`'s round-trip assertion, which derives its
  input FROM `Mount.label_keys()` itself (and so can never fail on a key that's read in
  source but missing from the whitelist — a tautology), this test's input is INDEPENDENT of
  the whitelist: it greps every `.ex` file under `lib/` for a `Mount.label(mount_expr, :key,
  default)` call site and collects every literal key argument found, then asserts that set is
  a SUBSET of `Mount.label_keys()`.

  Refutability: the input (source files) and the assertion target (`@label_keys`) are two
  independent artifacts, so adding a new `Mount.label(mount, :new_key, ...)` call site
  without adding `:new_key` to `@label_keys` makes this test fail on its own — no synthetic
  sabotage is needed to prove it CAN fail (proven live: see the luminary A4 fix report, which
  flipped this exact test red by removing a whitelisted key and restored it byte-exact).
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../../lib", __DIR__)
  @key_re ~r/Mount\.label\(\s*[^,]+,\s*:([a-zA-Z_][a-zA-Z0-9_]*)/

  test "every Mount.label/3 call site's key is in Mount.label_keys/0" do
    whitelist = MapSet.new(Samen.Web.Mount.label_keys())

    used =
      @lib_dir
      |> source_files()
      |> Enum.flat_map(&keys_used_in_file/1)
      |> MapSet.new()

    # A non-emptiness floor: if the scan itself breaks (wrong dir, regex stops matching),
    # this fails loud instead of vacuously passing on zero found call sites.
    assert MapSet.size(used) > 0,
           "found zero Mount.label(...) call sites under #{@lib_dir} — the scan itself broke"

    missing = MapSet.difference(used, whitelist)

    assert Enum.empty?(missing),
           "Mount.@label_keys (samen_web/lib/samen/web/mount.ex) is missing #{MapSet.size(missing)} " <>
             "key(s) actually read via Mount.label/3 in samen_web/lib: #{inspect(Enum.sort(missing))} " <>
             "— from_session/1 drops these on a cold BEAM unless they're whitelisted (the A4 bug)."
  end

  defp source_files(dir), do: Path.wildcard(Path.join(dir, "**/*.ex"))

  defp keys_used_in_file(path) do
    @key_re
    |> Regex.scan(File.read!(path))
    |> Enum.map(fn [_, key] -> String.to_atom(key) end)
  end
end
