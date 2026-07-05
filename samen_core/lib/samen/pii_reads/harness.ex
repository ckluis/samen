defmodule Samen.PiiReads.Harness do
  @moduledoc """
  Fail-closed driver for the `pii_reads` AST verifier (T1.8b).

  RED PATH contract (plan S0.7 / C3): `check_dirs/2` and `check_sources/2` return
  `{code, findings}` where `code` is 1 if any `:direct_leak` OR `:parse_error`
  finding is present, else 0. `:laundered_hint` findings are advisory and NEVER
  affect the code (the laundered path is J2's job, Phase 2). The mix task calls
  `:erlang.halt/1` with this code so CI fails closed.
  """

  alias Samen.PiiReads
  alias Samen.PiiReads.Registry

  @doc """
  Scan the given directories. Returns `{code, findings}`. `registry` defaults to
  one built from the configured `:ash_domains`.
  """
  @spec check_dirs([String.t()], Registry.t()) :: {0 | 1, [map()]}
  def check_dirs(dirs, registry \\ Registry.build()) do
    findings =
      Enum.flat_map(dirs, fn dir ->
        {:ok, fs} = PiiReads.scan_dir(dir, registry)
        fs
      end)

    {exit_code(findings), findings}
  end

  @doc "Same as check_dirs/2 but over in-memory `{file, source}` pairs."
  @spec check_sources([{String.t(), String.t()}], Registry.t()) :: {0 | 1, [map()]}
  def check_sources(pairs, registry \\ Registry.build()) do
    {:ok, findings} = PiiReads.scan_sources(pairs, registry)
    {exit_code(findings), findings}
  end

  @doc """
  1 if any direct-leak or parse-error finding is present, else 0.

  `:laundered_hint` findings are advisory and do NOT contribute to the code.
  """
  @spec exit_code([map()]) :: 0 | 1
  def exit_code(findings) do
    if Enum.any?(findings, &(&1.kind in [:direct_leak, :parse_error])), do: 1, else: 0
  end

  @doc "Only the findings that MUST fail the build (direct leaks + parse errors)."
  @spec failing(list()) :: list()
  def failing(findings) do
    Enum.filter(findings, &(&1.kind in [:direct_leak, :parse_error]))
  end

  @doc "Human-readable diagnostic (the verifier exits non-zero with a clear message)."
  @spec format(map()) :: String.t()
  def format(%{kind: :direct_leak} = f) do
    "PII LEAK  #{f.file}:#{f.line}  #{f.sink}(...) <- #{inspect(f.pii)}  " <>
      "[outside :reveal#{module_suffix(f)}]"
  end

  def format(%{kind: :parse_error} = f) do
    "PARSE ERR #{f.file}:#{f.line}  #{f.message}"
  end

  def format(%{kind: :laundered_hint} = f) do
    "LAUNDERED #{f.file}:#{f.line}  #{f.helper}(...) <- #{inspect(f.pii)}  [#{f.note}]"
  end

  defp module_suffix(%{module: nil}), do: ""
  defp module_suffix(%{module: mod}), do: ", #{inspect(mod)}"
  defp module_suffix(_), do: ""
end
