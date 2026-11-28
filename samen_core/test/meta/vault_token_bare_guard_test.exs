defmodule Samen.VaultTokenBareGuardTest do
  @moduledoc """
  Guard: no test (and no test-infra module that ships in lib, and no emitted test template) asserts on a bare
  `"vt_"` substring.

  `refute html =~ "vt_"` fails by chance on any page that renders a random URL-safe base64 token (the CSRF token of
  every workspace-switcher form, the signed LiveView session): the test fails once and passes on the rerun
  (`ReadsHonestFailureP3Test` "Account detail a failed read is the error state", 7 pages in 100 000). The one
  assertion is `Samen.VaultTokenAssert.refute_vault_token/3` (presence: `assert_vault_token/2`).

  Flagged, anywhere in a file (an assertion that starts on another line, a pipe, a capture, a module
  attribute or a helper all count; a comment-only line does not):

    * a regex sigil (`~r`/`~R` with any delimiter: `/ | { ( [ < " '`, single or multi-line) whose body spells
      `vt_` but not the full 32-hex grammar (`Regex.match?`, `String.match?`, `=~`, an attribute list);
    * the exact string `"vt_"` used as a match operand: after `=~`, or as an argument (or list element) of
      `String.contains?`, `String.match?` or `Regex.match?`.

  A hit may stay on purpose by saying why in a TRAILING comment on the line it starts on, `# bare-vt_-ok: <why>`
  (a marker inside a string, before the hit, or on another line does not count). The exact set of such
  exemptions is pinned below (file => number of lines): adding one means editing this test and saying why.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @apps ~w(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)
  # files that spell the bare check ON PURPOSE: this guard's controls, the helper and its own proof
  @exempt ~w(
    samen_core/test/meta/vault_token_bare_guard_test.exs
    samen_core/test/vault_token_assert_test.exs
    samen_core/lib/samen/vault_token_assert.ex
  )

  # Every exemption in the repo, pinned: `file => number of lines carrying a trailing marker`. Each is an assertion
  # about a MESSAGE that names the `vt_` marker (a verifier/ledger/prompt message), a production refusal of the marker,
  # an `^`-anchored check on field NAMES, or the one control that proves the old check fails; none is a
  # token-in-a-page check.
  @pinned %{
    "demo/test/api_serialization_boundary_test.exs" => 1,
    "samen_core/lib/samen/ai/agent.ex" => 1,
    "samen_core/lib/samen/delivery/rendered_email.ex" => 1,
    "samen_core/test/ai/agent_ingress_test.exs" => 1,
    "samen_core/test/ai/agent_loop_test.exs" => 1,
    "samen_core/test/ai/ai_prompt_masking_tool_checks_test.exs" => 1,
    "samen_core/test/ai/ai_prompt_masking_verifier_test.exs" => 1,
    "samen_core/test/ai/prompt_resource_test.exs" => 1,
    "samen_core/test/catalog_meaning_reader_test.exs" => 7,
    "samen_core/test/honest_kernel_reads_e_test.exs" => 2,
    "samen_web/test/samen/web/reads_honest_failure_p3_test.exs" => 1
  }

  @sigils (for {o, c} <- [{"/", "/"}, {"|", "|"}, {"{", "}"}, {"(", ")"}, {"[", "]"}, {"<", ">"}, {~s("), ~s(")}, {"'", "'"}] do
             Regex.compile!(
               "~[rR]" <> Regex.escape(o) <> "((?:\\\\.|[^\\\\" <> Regex.escape(c) <> "])*)" <> Regex.escape(c),
               "s"
             )
           end)

  # what comes right before an exact "vt_" literal that makes it a MATCH operand
  @match_context ~r/(=~\s*|String\.contains\?\([^)]*|String\.match\?\([^)]*|Regex\.match\?\([^)]*)\z/s
  @marker ~r/\s#\s*bare-vt_-ok:\s*\S/

  @doc false
  # `[{line_number, trimmed_line, marked?}]`, one per line holding at least one bare spelling.
  def bare_hits(source) when is_binary(source) do
    sigil_hits =
      for re <- @sigils,
          [{start, _len}, {bs, bl}] <- Regex.scan(re, source, return: :index),
          body = binary_part(source, bs, bl),
          String.contains?(body, "vt_"),
          not String.contains?(body, ["{32}", "\\{32\\}"]),
          do: start

    literal_hits =
      for [{start, _}] <- Regex.scan(~r/"vt_"/, source, return: :index),
          window = binary_part(source, max(start - 200, 0), min(start, 200)),
          Regex.match?(@match_context, window),
          do: start

    lines = String.split(source, "\n")

    (sigil_hits ++ literal_hits)
    |> Enum.map(&line_of(source, &1))
    |> Enum.uniq_by(fn {n, _col} -> n end)
    |> Enum.reject(fn {n, _col} -> comment_only?(Enum.at(lines, n - 1)) end)
    |> Enum.map(fn {n, col} ->
      line = Enum.at(lines, n - 1)
      {n, String.trim(line), marked?(line, col)}
    end)
  end

  defp line_of(source, pos) do
    before = binary_part(source, 0, pos)
    n = length(String.split(before, "\n"))
    col = byte_size(before) - (before |> String.split("\n") |> List.last() |> byte_size())
    {n, pos - col}
  end

  defp comment_only?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # A trailing comment AFTER the hit, outside any string.
  defp marked?(line, col) do
    case Regex.run(@marker, line, return: :index) do
      [{idx, _}] ->
        before = binary_part(line, 0, idx)
        idx > col and rem(length(String.split(before, ~s("))) - 1, 2) == 0

      _ ->
        false
    end
  end

  # kept for the controls below: the lines that would FAIL the guard (bare and not marked)
  @doc false
  def bare_lines(source), do: for({n, line, false} <- bare_hits(source), do: {n, line})

  defp files do
    tests =
      for app <- @apps,
          f <- Samen.SourceScan.files(Path.join([@root, app, "test"]), ~w(.ex .exs)),
          do: f

    lib =
      for app <- ~w(samen_core samen_web),
          f <- Samen.SourceScan.files(Path.join([@root, app, "lib"]), ~w(.ex)),
          do: f

    templates = Samen.SourceScan.files(Path.join(@root, "samen_core/priv/templates"), ~w(.eex))

    (tests ++ lib ++ templates)
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.reject(&(&1 in @exempt))
    |> Enum.sort()
  end

  test "no assertion in the repo is a bare \"vt_\" substring check, and the exemptions are exactly the pinned set" do
    hits =
      for rel <- files(),
          {n, line, marked?} <- bare_hits(Samen.SourceScan.read!(Path.join(@root, rel))),
          do: {rel, n, line, marked?}

    offenders = for {rel, n, line, false} <- hits, do: "#{rel}:#{n}: #{line}"

    assert offenders == [],
           "bare \"vt_\" substring assertions (flaky on random CSRF/session tokens, see the moduledoc):\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse Samen.VaultTokenAssert.refute_vault_token/3 / assert_vault_token/2"

    exempt = for {rel, _n, _line, true} <- hits, reduce: %{}, do: (acc -> Map.update(acc, rel, 1, &(&1 + 1)))

    assert exempt == @pinned,
           "the bare-vt_-ok exemptions changed (file => lines). Found: #{inspect(exempt, pretty: true)}"
  end

  test "positive control: the detector flags every bare spelling and passes the helper and the exact grammar" do
    flagged = fn src -> bare_lines(src) end

    for src <- [
          ~s|refute html =~ "vt_"|,
          ~s|    refute html =~ "vt_", "msg"|,
          ~s|assert Jason.encode!(x) =~ "vt_"|,
          ~s|refute html =~ ~r/\\bvt_/|,
          ~s|refute String.contains?(value, "vt_"), "raw"|,
          ~s|assert msg =~ "vt_" and msg =~ "x"|,
          # not an assert/refute line: a pipe, a capture, a comprehension, a bare expression
          ~S[html |> String.contains?("vt_") |> refute()],
          ~s|Enum.each(xs, &refute(&1 =~ "vt_"))|,
          ~s|x = html =~ "vt_"|,
          # Regex / String match functions and other sigil delimiters
          ~s|refute Regex.match?(~r/vt_/, html)|,
          "refute String.match?(html, ~r|vt_|)",
          ~s|refute html =~ ~r{\\bvt_}|,
          ~s|refute html =~ ~r(vt_)|,
          ~s|refute html =~ ~r"vt_"|,
          ~s|refute html =~ ~r[vt_]i|,
          # contains? with a list of needles
          ~s|refute String.contains?(html, ["pii_", "vt_"])|,
          # a module-attribute pattern list
          "@patterns [~r/\\bpii_/, ~r/\\bvt_/]",
          # multi-line
          "refute String.contains?(\n  html,\n  \"vt_\"\n)",
          "refute html =~\n  ~r/\n  vt_\n  /x",
          # a marker that does not count: inside a string, before the hit, on another line
          ~s|refute html =~ "vt_" <> "# bare-vt_-ok: x"|,
          ~s|# bare-vt_-ok: x\nrefute html =~ "vt_"|,
          ~s|refute "# bare-vt_-ok: x" =~ "vt_"|
        ] do
      assert [_ | _] = flagged.(src), "not flagged: #{inspect(src)}"
    end

    assert [{2, _}] = bare_lines("x = 1\nrefute out =~ \"vt_\"\n")

    for src <- [
          ~s|refute_vault_token(html)|,
          ~s|assert_vault_token(col)|,
          ~s|refute html =~ "vt_realtoken"|,
          ~s|assert col =~ ~r/\\Avt_[0-9a-f]{32}\\z/|,
          ~s|# refute html =~ "vt_"|,
          ~s|token = "vt_" <> hex|,
          ~s|String.starts_with?(value, "vt_")|,
          ~s|refute html =~ "vt"|
        ] do
      assert [] == flagged.(src), "wrongly flagged: #{inspect(src)}"
    end
  end

  test "a trailing # bare-vt_-ok: comment after the hit exempts exactly that line, and is reported as marked" do
    assert [{1, _, true}] = bare_hits(~s|assert msg =~ "vt_" # bare-vt_-ok: names the marker|)
    assert [{3, _, true}] = bare_hits("refute String.contains?(\n html,\n \"vt_\" # bare-vt_-ok: why\n)")
    assert [] == bare_lines(~s|assert msg =~ "vt_" # bare-vt_-ok: names the marker|)
    # a marker with no reason does not count
    assert [{1, _}] = bare_lines(~s|assert msg =~ "vt_" # bare-vt_-ok:|)
  end

  test "the scan is not vacuous: it sees the tests of every app and the shipped test infrastructure" do
    fs = files()
    assert length(fs) > 1000

    for app <- ~w(samen_core samen_web demo driftwood pawchart),
        do: assert(Enum.any?(fs, &String.starts_with?(&1, app <> "/test/")))

    assert "samen_core/lib/samen/masking_case.ex" in fs
    assert "samen_core/priv/templates/record_api_test.eex" in fs
    assert "demo/test/api_allowlist_test.exs" in fs
  end
end
