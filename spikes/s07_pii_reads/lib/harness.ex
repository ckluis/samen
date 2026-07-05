defmodule PiiReads.Harness do
  @moduledoc """
  Fail-closed driver for the `pii_reads` AST verifier.

  RED PATH contract (plan S0.7): `run/1` returns exit-code semantics —
  it exits/returns **1** when any direct leak is present in the scanned
  sources, and **0** on a clean corpus. The `mix pii_reads.verify` task
  calls `System.halt/1` with this code so CI fails closed.
  """

  alias PiiReads

  @doc """
  Scan the given directories. Returns `{code, findings}` where `code` is 1 if
  any `:direct_leak` (or `:parse_error`) finding exists, else 0.
  """
  @spec check_dirs([String.t()]) :: {0 | 1, [map()]}
  def check_dirs(dirs) do
    findings =
      dirs
      |> Enum.flat_map(fn dir ->
        {:ok, fs} = PiiReads.scan_dir(dir)
        fs
      end)

    code = exit_code(findings)
    {code, findings}
  end

  @doc "Same as check_dirs/1 but over in-memory `{file, source}` pairs."
  @spec check_sources([{String.t(), String.t()}]) :: {0 | 1, [map()]}
  def check_sources(pairs) do
    {:ok, findings} = PiiReads.scan_sources(pairs)
    {exit_code(findings), findings}
  end

  @doc "1 if any direct-leak or parse-error finding is present, else 0."
  @spec exit_code([map()]) :: 0 | 1
  def exit_code(findings) do
    if Enum.any?(findings, &(&1.kind in [:direct_leak, :parse_error])), do: 1, else: 0
  end

  @doc """
  Human-readable diagnostic (the verifier stack "exits non-zero on a
  violation" with a clear message — doc §775).
  """
  @spec format(map()) :: String.t()
  def format(%{kind: :direct_leak} = f) do
    "PII LEAK  #{f.file}:#{f.line}  #{f.sink}(...) <- #{inspect(f.pii)}" <>
      "  [outside :reveal]"
  end

  def format(%{kind: :parse_error} = f) do
    "PARSE ERR #{f.file}:#{f.line}  #{f.message}"
  end
end
