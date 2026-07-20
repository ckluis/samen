defmodule Samen.Gen.TemplatesParityTest do
  @moduledoc """
  BYTE-PARITY ORACLE for the `Samen.Gen.Templates` externalization refactor.

  The templated file set (`Samen.Gen.Templates.files/3`, piped through
  `Samen.Gen.App.render/2`) must be BYTE-FOR-BYTE identical before and after the emitter
  bodies are moved out of the god-file into `priv/templates/*.eex`. This test renders every
  emitted file for four representative configurations (headless, web, web+api,
  web+api+deploy) plus a `--modules` web variant (which exercises `home_live.ex` and the
  non-empty router mount seams), and asserts each rendered byte-string equals a frozen golden
  fixture captured from the PRE-refactor code.

  Golden fixtures live under `test/fixtures/templates_golden/<set>/<rendered_path>` and are
  committed with this test. To (re)capture them from the CURRENT code:

      SAMEN_UPDATE_GOLDEN=1 mix test test/templates_parity_test.exs

  The bindings are the REAL `Samen.Gen.App.bindings/1` of specs built via
  `Samen.Gen.App.build_spec/1` — which derives all abbrevs purely from the prefix and touches
  NEITHER the abbrev registry NOR the filesystem, so this test is hermetic and side-effect
  free. `target: Samen.Gen.App.default_target()` makes the `samen_core`/`samen_web` dep paths
  resolve to the stable `../samen_core` / `../samen_web`, so the golden is machine-independent.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App
  alias Samen.Gen.Templates

  @golden_root Path.join([__DIR__, "fixtures", "templates_golden"])

  # The mountable `--modules` surfaces (mirrors `Samen.Gen.App`'s private @mountable_modules)
  # — used only to decide whether the `home_live.ex` menu landing rides, exactly as
  # `Samen.Gen.App.files/1` does.
  @mountable [:files, :search, :csv, :settings]

  # {set_label, build_spec opts}. Fixed module/prefix/abbrev so the golden is deterministic.
  defp specs do
    base = [module: "Acme", prefix: "ac", abbrev: "acm", target: App.default_target()]

    [
      {"headless", Keyword.merge(base, web: false, api: false)},
      {"web", Keyword.merge(base, web: true, api: false)},
      {"web_api", Keyword.merge(base, web: true, api: true)},
      {"web_api_deploy", Keyword.merge(base, web: true, api: true, deploy: true)},
      {"web_api_modules",
       Keyword.merge(base, web: true, api: true, modules: "files,search,csv,settings,chat")}
    ]
  end

  # Mirror of `Samen.Gen.App.files/1` (private): the base Templates set for the spec's
  # (web?, api?, deploy?), plus the `home_live.ex` landing IFF the web layer is on and at
  # least one mountable surface was selected.
  defp file_set(%App{web?: web?, api?: api?, deploy?: deploy?, modules: mods} = _s) do
    base = Templates.files(web?, api?, deploy?)

    if web? and Enum.any?(mods, &(&1 in @mountable)) do
      base ++ [{"lib/<%= otp_app %>_web/home_live.ex", Templates.home_live_ex()}]
    else
      base
    end
  end

  # %{set_label => %{rendered_path => rendered_content}} for the CURRENT code.
  defp render_all do
    for {label, opts} <- specs(), into: %{} do
      s = App.build_spec(opts)
      b = App.bindings(s)

      rendered =
        for {path_tmpl, content_tmpl} <- file_set(s), into: %{} do
          {App.render(path_tmpl, b), App.render(content_tmpl, b)}
        end

      {label, rendered}
    end
  end

  # Golden files carry a `.golden` suffix so ExUnit does NOT try to compile the emitted
  # `*_test.exs` fixtures (they `use Acme.DataCase`, which only exists in a generated app).
  defp golden_path(set, rel), do: Path.join([@golden_root, set, rel]) <> ".golden"

  defp write_golden(actual) do
    File.rm_rf!(@golden_root)

    for {set, files} <- actual, {rel, content} <- files do
      dest = golden_path(set, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end
  end

  test "every emitted file is byte-identical to the frozen golden fixture" do
    actual = render_all()

    if System.get_env("SAMEN_UPDATE_GOLDEN") == "1" do
      write_golden(actual)
      IO.puts("\n[golden captured] #{@golden_root}")
    end

    assert File.dir?(@golden_root),
           "golden fixtures missing — capture first with SAMEN_UPDATE_GOLDEN=1"

    # 1. Every rendered file matches its golden byte-for-byte.
    for {set, files} <- actual, {rel, content} <- files do
      gp = golden_path(set, rel)

      assert File.exists?(gp), "no golden fixture for #{set}/#{rel} (re-capture golden)"
      assert File.read!(gp) == content, "byte drift in #{set}/#{rel}"
    end

    # 2. Set parity: no golden file is orphaned (a removed/renamed emitter would leave one).
    actual_keys =
      for {set, files} <- actual, {rel, _} <- files, into: MapSet.new(), do: {set, rel}

    golden_keys =
      for path <- Path.wildcard(Path.join(@golden_root, "**/*.golden"), match_dot: true),
          File.regular?(path),
          into: MapSet.new() do
        rel = Path.relative_to(path, @golden_root)
        [set | rest] = Path.split(rel)
        {set, Path.join(rest) |> String.replace_suffix(".golden", "")}
      end

    assert MapSet.difference(golden_keys, actual_keys) |> MapSet.to_list() == [],
           "orphaned golden fixtures (an emitter was removed/renamed without re-capture)"
  end
end
