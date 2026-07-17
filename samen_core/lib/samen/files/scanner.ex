defmodule Samen.Files.Scanner do
  @moduledoc """
  Pluggable file-scan contract for the files engine (ADR-026 §2, decision 3).

  Quarantine-by-default is the framework's fail-CLOSED posture applied to files: a
  freshly uploaded file lands `:quarantined` (see `Samen.Files.upload/3` and the
  `File.status` default) and is NOT previewable/downloadable until a scanner returns a
  **clean** verdict and the file is promoted to `:active` through
  `Samen.Files.promote/3`. The system never asserts a file is clean it has not scanned.

  A host selects a scanner per environment. The kernel ships two impls:

    * `Samen.Files.Scanner.Reject` — the **DEFAULT**. Fail-closed: every scan returns
      `{:ok, :held}`, so nothing ever promotes. Absent an explicitly-wired scanner, a
      file stays `:quarantined` forever — the honest posture until a real AV scanner is
      operator-wired (ClamAV/S3-scan are operator TODOs; no scanner dep ships in WS-E).
    * `Samen.Files.Scanner.Noop` — an **explicit operator opt-in**. Every scan returns
      `{:ok, :clean}` — i.e. "I am not actually scanning; promote regardless." This is
      honest by name (`Noop`) and honestly logged (`primitives.file.promoted` audit),
      and MUST be explicitly configured; it is never the default. It exists so dev/CI
      and operators who accept the risk can exercise the promotion lifecycle.

  ## The verdict contract (fail-honest)

  `scan/2` returns one of:

    * `{:ok, :clean}`  — the file passed; it MAY be promoted to `:active`.
    * `{:ok, :held}`   — the scanner declines to clear the file; it STAYS `:quarantined`.
    * `{:error, reason}` — the scan could not run (adapter not configured, backend
      down, …). This is fail-closed: a scan that could not run NEVER promotes.

  The load-bearing rule (mirrors the `Samen.Delivery.Adapter` fail-honest contract,
  ADR-014): a scanner that did not actually clear a file must NEVER return
  `{:ok, :clean}`. `Reject` — the default — returns `{:ok, :held}` precisely because it
  is not a real scanner; returning `{:ok, :clean}` from a non-scanning default would be
  the tautological lie this contract exists to abolish. Only `Noop`, an explicit and
  honestly-named opt-in, returns `{:ok, :clean}` — and the operator chose it.

  ## Web-dep-free

  This contract lives in `samen_core` and imposes no web/scanner dependency. A real
  scanner (ClamAV socket, an S3-scan Lambda, …) pulls its own client in the host app;
  the behaviour references none.
  """

  @typedoc "The scanner's verdict for a file's bytes."
  @type verdict :: :clean | :held

  @typedoc "Scanner configuration supplied by the host (socket, endpoint, creds, …)."
  @type config :: map()

  @doc """
  Scan the bytes of an uploaded file and return a verdict.

  Returns `{:ok, :clean}` ONLY when the scanner actually cleared the file (a real
  scanner that ran and found nothing, or the explicit `Noop` opt-in). Returns
  `{:ok, :held}` when the scanner declines to clear it (the `Reject` default), and
  `{:error, reason}` when the scan could not run. It must NEVER return `{:ok, :clean}`
  for a file it did not actually scan — that is the fail-honest rule the promotion
  gate relies on.
  """
  @callback scan(binary(), config()) :: {:ok, verdict()} | {:error, term()}
end
