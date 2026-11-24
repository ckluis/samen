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

  # A3 gate-parity guard (luminary pre-merge): EVERY generated app's ci.sh must run the B5
  # no_pan_columns sweep — the reference verticals (demo/driftwood/pawchart) all run it, and
  # before this guard the templates emitted a strictly WEAKER gate: a raw-DDL card_number
  # column that bypassed Ash was caught in driftwood and MISSED in an adopter's generated
  # app. Asserted on the RENDERED output (not the golden files) so a template edit that
  # drops the step fails HERE even after a golden re-capture — the leverage guarantee
  # ("generated apps get the reference verticals' enforcement") cannot silently regress.
  test "every generated ci.sh runs samen.verify.no_pan_columns (A3 gate parity with the reference verticals)" do
    for {set, files} <- render_all() do
      ci = files["ci.sh"]

      assert is_binary(ci), "#{set} emitted no ci.sh — the gate-parity guard has nothing to check"

      assert ci =~ "mix samen.verify.no_pan_columns",
             "#{set}/ci.sh is MISSING the B5 no_pan_columns step — a generated app would " <>
               "run a strictly weaker verifier gate than demo/driftwood/pawchart (the " <>
               "information_schema PAN sweep would never run in an adopter's CI)"
    end
  end

  # D3 phase 1: tenant isolation is Ash policy only, and `authorize?: false` turns it off — so EVERY
  # generated app's ci.sh must run the read-scope lint over its OWN lib/ (the reference hosts do), and
  # the app as emitted must PASS it with EXACTLY the sanction ceiling its ci.sh pins (the API-key
  # auth-step lookup is the one org-less read a fresh api app carries). Asserted on the RENDERED output,
  # so a template edit that drops the step, adds an unscoped read, or drifts the ceiling fails here even
  # after a golden re-capture.
  test "every generated ci.sh runs samen.verify.read_scope, and the rendered lib/ passes it at EXACTLY the pinned ceiling (D3 phase 1)" do
    for {set, files} <- render_all() do
      ci = files["ci.sh"]
      assert is_binary(ci), "#{set} emitted no ci.sh — the read-scope guard has nothing to check"

      lib_sources = for {path, src} <- files, String.starts_with?(path, "lib/"), String.ends_with?(path, ".ex"), do: {path, src}
      assert lib_sources != [], "#{set} emitted no lib/*.ex"

      {violations, sanctioned} =
        Enum.reduce(lib_sources, {[], 0}, fn {path, src}, {v, s} ->
          {viol, _gov, sanc} = Samen.Lint.ReadScope.scan_source(src, path)
          {v ++ viol, s + sanc}
        end)

      assert violations == [],
             "#{set}: the generated lib/ FAILS its own read-scope lint: #{inspect(violations)}"

      # a WHOLE, uncommented, unindented command line (a `# mix …` comment or an `|| true` tail must not satisfy it)
      assert ci =~ ~r/^mix samen\.verify\.read_scope --max-sanctioned #{sanctioned}$/m,
             "#{set}/ci.sh must run the read-scope lint pinned at the measured #{sanctioned} sanction(s) — " <>
               "an `authorize?: false` read added to a generated app would otherwise bypass org scoping unnoticed"
    end
  end

  # F3.4 deny-on-read: the generated api_key table carries `expires_at`, so the generated auth-step lookup must filter an
  # expired key out at the query (the demo host does). Without it an expired key kept authenticating: its actor map
  # carries no expiry, so `Samen.Scope.ApiKey.authorized?` could not refuse it either.
  test "every generated API key auth plug filters expired keys out of the lookup (F3.4 deny-on-read)" do
    plugs = for {set, files} <- render_all(), {path, src} <- files, String.ends_with?(path, "api/key_auth_plug.ex"), do: {set, src}
    assert plugs != [], "no generated app emitted an api/key_auth_plug.ex — the expiry guard has nothing to check"

    for {set, src} <- plugs do
      assert src =~ ~r/Samen\.Scope\.ApiKey\.active_query\(\w+\.Operator\.ApiKey, digest, now\)/,
             "#{set}: the generated API-key lookup is not the shared active_query (digest + revoked + expired) — an expired key could authenticate"
      refute src =~ "Ash.Query.filter(token_digest",
             "#{set}: the generated API-key lookup hand-rolls the digest filter instead of the shared query"
    end
  end

  # T60 framework-first guard: EVERY generated app's operator-mount migration must EMIT the
  # chat offline-escalation dedupe partial-unique index. This is stronger than the byte-golden
  # (which would silently accept a regenerated index-less golden): if a future template edit
  # drops the index and re-captures, THIS content assertion fails — so the leverage guarantee
  # (generated apps inherit the concurrent-double-escalation backstop) cannot silently regress.
  test "every generated operator-mount migration EMITS the chat-escalation dedupe partial-unique index (T60)" do
    goldens =
      Path.wildcard(Path.join(@golden_root, "*/priv/repo/migrations/*mount_operator_scopes.exs.golden"))

    assert goldens != [], "no operator-mount goldens found — regenerate with SAMEN_UPDATE_GOLDEN=1"

    for g <- goldens do
      src = File.read!(g)
      rel = Path.relative_to(g, @golden_root)

      assert src =~ ~r/create\(\s*unique_index\(:\w+_ticket, \[:\w+_org_id, :\w+_external_id\]/,
             "operator-mount golden #{rel} is MISSING the chat-escalation dedupe UNIQUE index"

      assert src =~ ~r/\w+_ticket_chat_dedupe_idx/,
             "operator-mount golden #{rel} is missing the dedupe index NAME"

      assert src =~ ~r/where: "\w+_external_id IS NOT NULL"/,
             "operator-mount golden #{rel} dedupe index is not PARTIAL (external_id IS NOT NULL)"
    end
  end

  # ADR-043 §8a (A3): a generated app is correct by construction w.r.t. the catalog-meaning verifier its OWN ci.sh runs.
  # Asserted on the RENDERED output (not the goldens), so a template that drops a description fails here even after a
  # golden re-capture. The descriptions are read from the AST of the emitted source.
  defp vertical_descriptions(src) do
    {:ok, ast} = Code.string_to_quoted(src)

    {_, acc} =
      Macro.prewalk(ast, %{resource: [], fields: %{}}, fn
        {:resource, _, [[do: {:description, _, [d]}]]} = n, acc when is_binary(d) ->
          {n, %{acc | resource: [d | acc.resource]}}

        {call, _, [name, _type, opts]} = n, acc when call in [:attribute, :pii_attribute] and is_list(opts) ->
          {n, %{acc | fields: Map.put(acc.fields, name, opts[:description])}}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  test "every generated vertical resource describes itself and its name, segment and vault fields (ADR-043 §8a)" do
    for {set, files} <- render_all() do
      src = files["lib/acme/vertical.ex"]
      %{resource: resource, fields: fields} = vertical_descriptions(src)

      assert [description] = resource, "#{set}: the vertical Record carries no resource description"
      assert Samen.CatalogMeaning.description_problems(description, ["Record", "record", "acm_record"]) == []
      assert Map.keys(fields) |> Enum.sort() == [:name, :secret, :segment]

      for {name, d} <- fields do
        assert is_binary(d), "#{set}: vertical field #{name} is emitted WITHOUT a description — the generated app's own verifier would fail"
        assert Samen.CatalogMeaning.description_problems(d, [to_string(name)]) == [], "#{set}: #{name}: #{inspect(d)}"
        refute d =~ "vt_"
      end

      # The plane wording is what `Samen.Api.PiiResolution` does (pii_resolution_planes_test.exs pins that behaviour):
      # a tenant key reads its own org in clear with no grant; other planes see it masked or omitted without a grant.
      assert fields[:secret] =~ "clear on the owning organization's tenant plane", "#{set}: #{inspect(fields[:secret])}"
      assert fields[:secret] =~ "masked or omitted on other planes", "#{set}: #{inspect(fields[:secret])}"
      refute fields[:secret] =~ "on every read", "#{set}: the vault field is not masked on every read"
    end
  end

  test "every generated aggregate resource describes itself and its five fields, and says only what the read path enforces (ADR-043 §8a)" do
    for {set, files} <- render_all() do
      %{resource: resource, fields: fields} = vertical_descriptions(files["lib/acme/aggregate.ex"])

      assert [description] = resource, "#{set}: the aggregate resource carries no description"

      assert Samen.CatalogMeaning.description_problems(description, ["RecordCountBySegment", "record_count_by_segment", "acm_record_count"]) == []

      assert Map.keys(fields) |> Enum.sort() == [:org_id, :record_count, :refreshed_at, :segment, :tenant_count]

      for {name, d} <- fields do
        assert is_binary(d), "#{set}: aggregate field #{name} is emitted WITHOUT a description — the generated app's own verifier would fail"
        assert Samen.CatalogMeaning.description_problems(d, [to_string(name)]) == [], "#{set}: #{name}: #{inspect(d)}"
      end

      # k-anonymity suppression happens in `Samen.Aggregate.read_all/2` (a raw Ash.read returns raw values), and nothing in
      # the generated app fills the summary table: the text says the first and claims nothing of the second.
      assert fields[:record_count] =~ "Samen.Aggregate read path"
      assert fields[:tenant_count] =~ "Samen.Aggregate read path"
      refute description =~ "readable only by"
    end
  end

  test "the aggregate check is not vacuous: stripping one aggregate description is detected" do
    src = render_all()["web"]["lib/acme/aggregate.ex"]
    stripped = String.replace(src, ~r/,\n\s+description: "Number of items[^"]*"/, "", global: false)
    refute stripped == src
    assert vertical_descriptions(stripped).fields[:record_count] == nil
  end

  test "the field check is not vacuous: stripping one description from the rendered vertical is detected" do
    src = render_all()["web"]["lib/acme/vertical.ex"]
    stripped = String.replace(src, ~r/,\n\s+description: "Name of the item[^"]*"/, "", global: false)
    refute stripped == src
    assert vertical_descriptions(stripped).fields[:name] == nil
  end

  test "every generated ci.sh runs samen.verify.catalog_meaning as step 1c, right after the dict drift check (ADR-043 §8a)" do
    for {set, files} <- render_all() do
      ci = files["ci.sh"]

      assert ci =~ ~r/^mix samen\.verify\.catalog_meaning$/m,
             "#{set}/ci.sh does not run the catalog-meaning verifier — its baseline and descriptions would never be enforced"

      {drift, meaning, parity} =
        {pos(ci, "step 1b/"), pos(ci, "mix samen.verify.catalog_meaning\n"), pos(ci, "mix samen.verify.catalog_parity\n")}

      assert drift < meaning and meaning < parity, "#{set}: step 1c must sit between the dict drift check and catalog_parity"
    end
  end

  defp pos(text, needle), do: text |> :binary.match(needle) |> elem(0)
end
