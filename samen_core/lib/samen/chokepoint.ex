defmodule Samen.Chokepoint do
  @moduledoc """
  The **single decrypt chokepoint** structural scanner (T1.5 clause (b), ported
  from the S0.5 spike `plaintext_leak_test`).

  There must be exactly ONE place in `samen_core` that decrypts vault ciphertext
  for a read: `Samen.Vault.do_decrypt/2`, invoked only by the reveal path. A
  second `Kms.Crypto.decrypt/…` call site anywhere else is a structural violation:
  a laundered decrypt that bypasses `%Masked{}` and the `Samen.Reveal` grant gate.
  This scanner finds every literal `Crypto.decrypt(` call site in a source tree so
  a test can assert there is exactly one, in the sanctioned module.

  ## Literal-match limitation (C3 is the real check)

  This is a **literal string scan**, deliberately. It matches the text
  `Crypto.decrypt(`. It therefore does NOT catch:

    * an aliased module — `alias Samen.Kms.Crypto, as: C; C.decrypt(...)`
    * a fully-qualified call — `Samen.Kms.Crypto.decrypt(...)`
    * a direct `:crypto.crypto_one_time/…` / `:crypto` primitive call
    * a decrypt reached through a captured/`apply/3` indirection

  These are precisely the evasions the C3 `pii_reads` AST verifier (T1.8b) exists
  to catch — an AST/dataflow check keyed on the vault DECLARATION, not on a text
  match. The Gate-0 report (S0.5 caveat) records this explicitly: the structural
  scanner is a cheap in-repo backstop that proves the single-chokepoint property
  is *real and enforceable in tests*, while C3 is the sound-ish check. Keeping both
  is the layered design.

  The scanner also normalizes for its own limitation by matching only the exact
  sanctioned alias form the vault uses (`Crypto.decrypt(`), so if someone renames
  the alias to evade this scan, the C2/C3 verifiers and the aliased-call awareness
  in C3 are the backstop.
  """

  @sanctioned_module "samen/vault.ex"
  @sanctioned_fun "do_decrypt"

  @doc """
  All literal `Crypto.decrypt(` CALL sites under `lib_dir`. Returns a list of
  `{relative_path, trimmed_line, line_number}`.

  Excludes non-code occurrences of the pattern so the scanner does not flag its
  own documentation or ordinary comments:

    * comment lines (first non-space char is `#`), and
    * lines where the pattern appears inside backticks (doc/moduledoc prose,
      e.g. this module documenting `Crypto.decrypt(`).

  It also excludes `chokepoint.ex` itself — this module names the pattern by
  design (the scanner cannot be a decrypt call site). What remains is actual
  source CALLs to `Crypto.decrypt(`.
  """
  @spec decrypt_call_sites(Path.t()) :: [{String.t(), String.t(), pos_integer()}]
  def decrypt_call_sites(lib_dir) do
    for file <- Path.wildcard(Path.join(lib_dir, "**/*.ex")),
        Path.basename(file) != "chokepoint.ex",
        {line, idx} <- Enum.with_index(File.read!(file) |> String.split("\n"), 1),
        code_call_site?(line) do
      {Path.relative_to(file, lib_dir), String.trim(line), idx}
    end
  end

  # A line is a decrypt CALL site if it contains `Crypto.decrypt(` as code — not
  # in a `#` comment and not inside backticked doc prose.
  defp code_call_site?(line) do
    String.contains?(line, "Crypto.decrypt(") and
      not comment_line?(line) and
      not in_backticks?(line, "Crypto.decrypt(")
  end

  defp comment_line?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # Does the pattern appear inside a backtick span on this line? (doc prose)
  defp in_backticks?(line, pattern) do
    case :binary.match(line, pattern) do
      {pos, _len} ->
        before = binary_part(line, 0, pos)
        # Odd number of backticks before the pattern ⇒ inside a backtick span.
        before |> String.graphemes() |> Enum.count(&(&1 == "`")) |> rem(2) == 1

      :nomatch ->
        false
    end
  end

  @doc """
  Assert the single-chokepoint property for a source tree: exactly one literal
  `Crypto.decrypt(` call site, and it lives in the sanctioned module.

  Returns `:ok` or `{:error, reason}` with a human diagnostic. A test wraps this
  in an `assert`.
  """
  @spec single_chokepoint(Path.t()) :: :ok | {:error, String.t()}
  def single_chokepoint(lib_dir) do
    case decrypt_call_sites(lib_dir) do
      [{@sanctioned_module, _line, _n}] ->
        :ok

      [] ->
        {:error, "no Crypto.decrypt/2 call site found — the reveal chokepoint is missing"}

      sites ->
        {:error,
         "expected exactly ONE Crypto.decrypt/2 call site (the reveal chokepoint in " <>
           "#{@sanctioned_module}), got #{length(sites)}:\n" <>
           Enum.map_join(sites, "\n", fn {f, l, n} -> "  #{f}:#{n}  #{l}" end)}
    end
  end

  @doc """
  The sanctioned module/function names, for diagnostics and tests.
  """
  @spec sanctioned() :: %{module: String.t(), fun: String.t()}
  def sanctioned, do: %{module: @sanctioned_module, fun: @sanctioned_fun}
end
