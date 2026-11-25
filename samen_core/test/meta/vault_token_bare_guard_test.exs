defmodule Samen.VaultTokenBareGuardTest do
  @moduledoc """
  Guard: no test (and no test-infra module that ships in lib, and no emitted test template) asserts on a bare
  `"vt_"` substring.

  `refute html =~ "vt_"` fails by chance on any page that renders a random URL-safe base64 token (the CSRF token of
  every workspace-switcher form, the signed LiveView session): the test fails once and passes on the rerun
  (`ReadsHonestFailureP3Test` "Account detail a failed read is the error state", 7 pages in 100 000). The one
  assertion is `Samen.VaultTokenAssert.refute_vault_token/3` (presence: `assert_vault_token/2`).

  Flagged, on an `assert`/`refute` line that is not a comment: `=~ "vt_"`, `=~ ~r/…vt_…/` whose regex does not spell
  the full 32-hex grammar, and `String.contains?(x, "vt_")`. A line may keep a bare prefix on purpose by saying why
  after `# bare-vt_-ok:` (an assertion about a message that NAMES the marker, not about a token in a page).
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

  @bare ~r/=~\s*"vt_"|String\.contains\?\([^)]*"vt_"\)|=~\s*~r\/[^\/\n]*vt_[^\/\n]*\//

  @doc false
  def bare_lines(source) when is_binary(source) do
    for {line, n} <- source |> String.split("\n") |> Enum.with_index(1),
        trimmed = String.trim_leading(line),
        not String.starts_with?(trimmed, "#"),
        String.starts_with?(trimmed, ["assert", "refute"]),
        not String.contains?(line, "bare-vt_-ok:"),
        bare?(line),
        do: {n, String.trim(line)}
  end

  defp bare?(line) do
    case Regex.run(@bare, line) do
      nil -> false
      [hit] -> not String.contains?(hit, "{32}")
    end
  end

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

  test "no assertion in the repo is a bare \"vt_\" substring check" do
    offenders =
      for rel <- files(),
          {n, line} <- bare_lines(Samen.SourceScan.read!(Path.join(@root, rel))),
          do: "#{rel}:#{n}: #{line}"

    assert offenders == [],
           "bare \"vt_\" substring assertions (flaky on random CSRF/session tokens, see the moduledoc):\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse Samen.VaultTokenAssert.refute_vault_token/3 / assert_vault_token/2"
  end

  test "positive control: the detector flags every bare spelling and passes the helper and the exact grammar" do
    assert [{1, _}] = bare_lines(~s|refute html =~ "vt_"|)
    assert [{1, _}] = bare_lines(~s|    refute html =~ "vt_", "msg"|)
    assert [{1, _}] = bare_lines(~s|assert Jason.encode!(x) =~ "vt_"|)
    assert [{1, _}] = bare_lines(~s|refute html =~ ~r/\\bvt_/|)
    assert [{1, _}] = bare_lines(~s|refute String.contains?(value, "vt_"), "raw"|)
    assert [{1, _}] = bare_lines(~s|assert msg =~ "vt_" and msg =~ "x"|)
    assert [{2, _}] = bare_lines("x = 1\nrefute out =~ \"vt_\"\n")

    assert [] == bare_lines(~s|refute_vault_token(html)|)
    assert [] == bare_lines(~s|assert_vault_token(col)|)
    assert [] == bare_lines(~s|refute html =~ "vt_realtoken"|)
    assert [] == bare_lines(~s|assert col =~ ~r/\\Avt_[0-9a-f]{32}\\z/|)
    assert [] == bare_lines(~s|# refute html =~ "vt_"|)
    assert [] == bare_lines(~s|assert msg =~ "vt_" # bare-vt_-ok: names the marker|)
    assert [] == bare_lines(~s|token = "vt_" <> hex|)
  end

  test "the scan is not vacuous: it sees the tests of every app and the shipped test infrastructure" do
    fs = files()
    assert length(fs) > 1000

    for app <- ~w(samen_core samen_web demo driftwood pawchart),
        do: assert(Enum.any?(fs, &String.starts_with?(&1, app <> "/test/")))

    assert "samen_core/lib/samen/masking_case.ex" in fs
  end
end
