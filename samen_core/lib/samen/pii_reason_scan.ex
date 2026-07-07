defmodule Samen.PiiReasonScan do
  @moduledoc """
  Best-effort, fail-closed **value-shape scan** for operator-authored free-text
  metadata (F4.3, Gate-4 carry).

  ## The gap this closes

  Impersonation-session `reason`s, reveal-request `reason`s, and audit-chain / audit-event
  `detail` strings are **operator-authored plaintext metadata**. Unlike the vaulted PII
  columns, this text is NOT crypto-shreddable — it is stored in `imp_impersonation_session`,
  `rvr_reveal_request`, `aud_event.aud_detail`, and the hash-committed `aud_chain` payload
  as plaintext, and a subject erasure (crypto-shred) does NOT erase it (destroying a
  subject's DEK cannot reach a plaintext column; and the audit chain's hash commits to the
  detail token so it is deliberately preserved). See ADR-002 §2.5.

  So the honest posture is: keep this channel **free of subject PII in the first place**.
  The load-bearing control is a **human/process convention** ("reasons name the ticket, not
  the person") plus this scan as a fail-closed belt at the write boundary.

  ## What the scan does — and does NOT

  `scan/1` runs `Samen.PiiValueShape.classify_value/1` over the free-text — the
  **email / SSN / phone** shapes only. It **deliberately excludes the space-separated-name
  shape**: a legitimate reason ("customer #1234 reported a billing error") has internal
  spaces, so the name heuristic would reject nearly every real reason. Names are not
  reliably distinguishable from ordinary prose by shape, so we do not gate on them here;
  the human convention carries that case, and the moduledoc/ADR name the residue explicitly.

  This is a **heuristic, not a taint proof** (same caveat as `Samen.PiiValueShape`): it
  catches the obvious mistake of pasting an email/SSN/phone into a reason. It cannot prove a
  reason is PII-free.

  ## Fail-closed default: REJECT

  `check!/1` (and the wired callers) **reject** a PII-shaped reason with a clear
  `{:error, {:pii_shaped_reason, shape}}` at write time, BEFORE any DB write — so a
  session/grant/audit row carrying an email/SSN/phone-shaped reason never lands. This is
  the fail-closed choice over "warn and store": storing plaintext PII in a non-shreddable
  channel is exactly the leak we cannot later erase, so we refuse it up front. A `Logger`
  warning is also emitted (belt-and-suspenders visibility).
  """

  require Logger

  alias Samen.PiiValueShape

  @typedoc "Result of scanning a free-text reason/detail string."
  @type result :: :ok | {:pii_shaped, :email | :ssn | :phone}

  @doc """
  Scan a free-text reason/detail. Returns `:ok` for a normal reason (or nil/blank),
  `{:pii_shaped, shape}` when the WHOLE string matches an email/SSN/phone value shape.

  Only a value that is *itself* a bare email/SSN/phone is flagged (the value-shape
  regexes are anchored). A sentence that merely mentions a topic is not flagged.
  """
  @spec scan(term()) :: result()
  def scan(text) when is_binary(text) do
    trimmed = String.trim(text)

    case PiiValueShape.classify_value(trimmed) do
      {true, shape} -> {:pii_shaped, shape}
      {false, nil} -> :ok
    end
  end

  def scan(_), do: :ok

  @doc """
  Fail-closed guard for the write path. Returns `:ok` for a normal reason; returns
  `{:error, {:pii_shaped_reason, shape}}` (and logs a warning) for a PII-shaped one, so
  the caller can refuse the write.

  `field` is a label used only in the log line (e.g. `"impersonation reason"`).
  """
  @spec check(term(), String.t()) :: :ok | {:error, {:pii_shaped_reason, atom()}}
  def check(text, field \\ "reason") do
    case scan(text) do
      :ok ->
        :ok

      {:pii_shaped, shape} ->
        Logger.warning(
          "Samen.PiiReasonScan: rejected a #{shape}-shaped #{field} — " <>
            "operator-authored reason/detail is a NON-shreddable plaintext channel " <>
            "(ADR-002 §2.5); it must not carry subject PII. Refusing the write."
        )

        {:error, {:pii_shaped_reason, shape}}
    end
  end
end
