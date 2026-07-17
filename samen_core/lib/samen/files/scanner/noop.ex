defmodule Samen.Files.Scanner.Noop do
  @moduledoc """
  The explicit-opt-in file scanner (ADR-026 §2, decision 3).

  `Noop` is honest by name: it does NOT actually scan. Every scan returns
  `{:ok, :clean}`, so `Samen.Files.promote/3` will promote a `:quarantined` file to
  `:active`. It exists so dev/CI — and operators who consciously accept the risk of
  running without a real AV scanner — can exercise the upload → scan → promote → preview
  lifecycle.

  It is NEVER the default. A host must explicitly wire it:

      config :samen_core, Samen.Files, scanner: Samen.Files.Scanner.Noop

  The default is `Samen.Files.Scanner.Reject`, which holds every file. Because promotion
  runs through `Samen.Files.promote/3`, the choice to auto-promote unscanned files is an
  explicit, honestly-named, honestly-audited operator decision (`primitives.file.promoted`)
  — never a silent default.
  """
  @behaviour Samen.Files.Scanner

  @impl Samen.Files.Scanner
  def scan(binary, _config) when is_binary(binary), do: {:ok, :clean}
  def scan(_binary, _config), do: {:error, :invalid_argument}
end
