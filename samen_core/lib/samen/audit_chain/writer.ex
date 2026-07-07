defmodule Samen.AuditChain.Writer do
  @moduledoc """
  The one call that writes an `aud_event` row AND its `aud_chain` entry together
  (T4.3; ADR-002). Reuses `Samen.AuditEvent.insert/2` (never duplicates it) and
  appends the linked chain entry via `Samen.AuditChain.append/2` in the SAME repo
  connection, so an event and its chain entry commit atomically — an event without a
  chain link, or a chain link without its event, never exists.

  ## Usage

      Samen.AuditChain.Writer.write(repo, %{
        org_id:         org_id,        # per-org chain partition ("__global__" if org-less)
        event_type:     "reveal",      # bounded enum, mirrors aud_event
        subject_id:     subject_id,    # opaque token — NOT plaintext
        actor_id:       operator_id,
        correlation_id: grant_id,
        detail:         "event=granted …",
        occurred_at:    DateTime.utc_now(),
        subject_payload: nil           # OPTIONAL: key-destroyable ciphertext (needs subject_id)
      })

  Returns `{:ok, %{aud_event: aud, chain: entry}}` or `{:error, term}`. If the
  `aud_chain` table is not yet deployed (a host that has not run the T4.3 migration),
  the chain append is skipped gracefully and only the `aud_event` row lands — the same
  graceful-degradation posture `Samen.Reveal.Grants.write_audit/2` takes for the
  `aud_event` tier itself.

  ## Where it plugs in

  Wraps the existing writers so they gain a chain entry with no per-caller rewrite:
    * `Samen.Reveal.Grants.write_audit/2` (reveal/grant lifecycle)
    * `Samen.Impersonation.Sessions.emit_event/3` (impersonation open/close/expiry)
    * `Samen.Erasure` (erasure events)

  Each maps its own attrs to the token-only shape above.

  ## `detail` is a non-shreddable plaintext channel (F4.3)

  The `detail` field is operator-authored plaintext, hash-committed into the chain and
  preserved through crypto-shred (ADR-002 §2.5). `write/2` runs
  `Samen.PiiReasonScan.check/2` on it (email/SSN/phone value-shape scan, fail-closed
  REJECT) and returns `{:error, {:pii_shaped_reason, shape}}` for a bare PII-shaped
  detail — refusing the write before subject PII enters the immutable chain. Best-effort
  belt, not a taint proof.
  """

  alias Samen.{AuditEvent, AuditChain}

  @doc """
  Write the `aud_event` row and its linked `aud_chain` entry. Runs in `repo`'s current
  connection (call from inside the caller's transaction for atomicity).

  `attrs` (all token-only): `:org_id`, `:event_type`, `:subject_id`, `:actor_id`,
  `:correlation_id`, `:detail`, `:occurred_at`, `:subject_payload` (optional).
  """
  @spec write(module(), map()) :: {:ok, map()} | {:error, term}
  def write(repo, attrs) when is_atom(repo) and is_map(attrs) do
    with :ok <- Samen.PiiReasonScan.check(get(attrs, :detail), "audit detail") do
      do_write(repo, attrs)
    end
  end

  # F4.3: the audit `detail` is a NON-shreddable plaintext channel (ADR-002 §2.5) — it is
  # hash-committed into the aud_chain payload and preserved through crypto-shred. Reject a
  # detail that is *itself* an email/SSN/phone value shape BEFORE the write (fail-closed
  # default), so subject PII never enters the tamper-evident chain. Composed details
  # (`event=… reason=…`) are not bare value shapes and pass; the per-source reason scans
  # (Sessions.open/1, Grants.request/1) already gate the reason component upstream — this
  # is the last-line belt at the shared chain write boundary, also covering direct callers.
  defp do_write(repo, attrs) do
    aud_attrs = %{
      event_type: to_string(get(attrs, :event_type) || "system"),
      subject_id: str(get(attrs, :subject_id)),
      actor_id: str(get(attrs, :actor_id)),
      correlation_id: get(attrs, :correlation_id),
      detail: get(attrs, :detail),
      occurred_at: occurred_at(attrs)
    }

    with {:ok, aud} <- AuditEvent.insert(repo, aud_attrs) do
      chain_attrs =
        attrs
        |> Map.put(:aud_id, aud.id)
        |> Map.put_new(:occurred_at, aud.occurred_at)

      case append_chain(repo, chain_attrs) do
        {:ok, entry} -> {:ok, %{aud_event: aud, chain: entry}}
        {:skip, _} -> {:ok, %{aud_event: aud, chain: :skipped}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Append the chain entry. If the aud_chain table is absent (host not yet migrated),
  # skip gracefully — the aud_event row already landed. The existence CHECK happens
  # BEFORE the insert (a cheap `to_regclass` probe) precisely because attempting an
  # INSERT into a missing table inside the caller's transaction would ABORT the whole
  # transaction (Postgres 25P02) — a rescue cannot un-poison it. Probing first keeps
  # the graceful-skip real inside a multi.
  defp append_chain(repo, chain_attrs) do
    if aud_chain_exists?(repo) do
      AuditChain.append(chain_attrs, repo: repo)
    else
      {:skip, :aud_chain_absent}
    end
  end

  defp aud_chain_exists?(repo) do
    %{rows: [[reg]]} = repo.query!("SELECT to_regclass('public.aud_chain')")
    reg != nil
  rescue
    _ -> false
  end

  defp occurred_at(attrs) do
    case get(attrs, :occurred_at) do
      %DateTime{} = dt -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))
  defp str(nil), do: nil
  defp str(v), do: to_string(v)
end
