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

  ## Atomicity and nesting

  The event and its chain entry are one unit on every path. Outside a transaction the write opens its own; inside a
  caller's transaction it runs in a SAVEPOINT, so an `{:error, _}` leaves neither row behind even when the caller
  tolerates the error and goes on (Ecto does not nest plain rollbacks, so only a savepoint can undo this pair
  without poisoning the caller's transaction). A caller that grants, opens or approves something must still roll
  back on `{:error, _}`: the audit failure means the action is unaudited. An unavailable chain (the existence probe
  failed) writes nothing in either case.

  ## Where it plugs in

  Wraps the existing writers so they gain a chain entry with no per-caller rewrite:
    * `Samen.Reveal.Grants.write_audit/2` (reveal/grant lifecycle)
    * `Samen.Impersonation.Sessions.emit_event/3` (impersonation open/close/expiry)
    * `Samen.Erasure` (erasure events)

  Each maps its own attrs to the token-only shape above.

  ## `occurred_at` is the partition key — and caller-supplied

  A past `occurred_at` is kept as given (a deferred break-glass anchor, a replay or an import legitimately
  carries the time the thing happened); older than every partition, it lands in the DEFAULT partition and is
  reported. One further ahead than `:audit_future_skew_seconds` (default 300) is CLAMPED to the write time, the
  claimed time is appended to `detail` (`occurred_at_claimed=…`), and the clamp is reported — never rejected,
  because rejecting would let a timestamp make an audited privileged action fail. See ADR-002 amendment.

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
      # Atomic: an `aud_event` without its chain entry never persists. Outside a transaction the insert and the
      # chain append share one of their own; inside a caller's, they share a savepoint (see `in_savepoint/2`). The
      # probe runs BEFORE any insert, so an unavailable chain writes nothing in either case.
      if repo.in_transaction?() do
        in_savepoint(repo, get(attrs, :org_id), fn -> do_write(repo, attrs) end)
      else
        case repo.transaction(fn ->
               case do_write(repo, attrs) do
                 {:ok, written} -> written
                 {:error, reason} -> repo.rollback(reason)
               end
             end) do
          {:ok, written} -> {:ok, written}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # Inside a caller's transaction the pair runs in a SAVEPOINT (Ecto has no nested rollback: `repo.rollback` in a
  # nested `transaction` poisons the caller's). The pair is undone on EVERY way out of `fun`:
  #   * a returned `{:error, _}` (the chain append failed AFTER the event insert: a subject key that cannot be
  #     unwrapped, a rejected row) rolls back TO the savepoint;
  #   * a RAISE, EXIT or THROW (a KMS adapter that raises in `unwrap/1`, a crypto failure) does too (best effort), and is
  #     then re-raised unchanged. A non-DB raise does NOT abort Postgres, so without this the `aud_event` stayed behind,
  #     unchained, in a transaction the caller then committed. A raise from a DB error OUTSIDE `AuditChain.append`'s own
  #     nested transaction (the plain event insert) is undone by the rollback to the savepoint, which also clears the
  #     aborted state. A raise INSIDE `append`'s nested transaction (the advisory-lock query, `do_append`) leaves the
  #     caller's transaction FAILED: DBConnection refuses every further query, so the rollback to the savepoint itself
  #     fails (reported once more as `audit_chain_savepoint`), the original exception is re-raised, and the caller's
  #     commit becomes a rollback. That is the safe direction; the second report is accepted, not suppressed.
  # The savepoint statements are `query/2`s, not `query!/2`s, and a failure of one is the same
  # `{:error, :audit_chain_unavailable}` (reported by name) the existence probe answers: an already-aborted caller
  # transaction, or a dropped connection, is an error tuple, never a raised 25P02 that hides the reason. The savepoint takes
  # no lock of its own; the advisory lock the append takes is taken at the same point as before.
  defp in_savepoint(repo, org_id, fun) do
    sp = "samen_audit_write_#{System.unique_integer([:positive])}"

    case savepoint(repo, "SAVEPOINT ", sp, org_id) do
      :ok -> run_in_savepoint(repo, org_id, sp, fun)
      {:error, _} = error -> error
    end
  end

  defp run_in_savepoint(repo, org_id, sp, fun) do
    case fun.() do
      {:ok, _} = ok ->
        with :ok <- savepoint(repo, "RELEASE SAVEPOINT ", sp, org_id), do: ok

      {:error, _} = error ->
        with :ok <- savepoint(repo, "ROLLBACK TO SAVEPOINT ", sp, org_id),
             :ok <- savepoint(repo, "RELEASE SAVEPOINT ", sp, org_id),
             do: error
    end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      # best effort, and never in place of the original failure: a dead connection must not replace the exception
      with :ok <- savepoint(repo, "ROLLBACK TO SAVEPOINT ", sp, org_id), do: savepoint(repo, "RELEASE SAVEPOINT ", sp, org_id)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp savepoint(repo, statement, sp, org_id) do
    case repo.query(statement <> sp) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Samen.Observability.Failure.report_write(:audit_chain_savepoint, org_id, reason)
        {:error, :audit_chain_unavailable}
    end
  rescue
    e ->
      Samen.Observability.Failure.report_write(:audit_chain_savepoint, org_id, e)
      {:error, :audit_chain_unavailable}
  end

  # F4.3: the audit `detail` is a NON-shreddable plaintext channel (ADR-002 §2.5) — it is
  # hash-committed into the aud_chain payload and preserved through crypto-shred. Reject a
  # detail that is *itself* an email/SSN/phone value shape BEFORE the write (fail-closed
  # default), so subject PII never enters the tamper-evident chain. Composed details
  # (`event=… reason=…`) are not bare value shapes and pass; the per-source reason scans
  # (Sessions.open/1, Grants.request/1) already gate the reason component upstream — this
  # is the last-line belt at the shared chain write boundary, also covering direct callers.
  defp do_write(repo, attrs) do
    {occurred_at, detail, clamped?} = occurred_at_and_detail(attrs)

    aud_attrs = %{
      event_type: to_string(get(attrs, :event_type) || "system"),
      subject_id: str(get(attrs, :subject_id)),
      actor_id: str(get(attrs, :actor_id)),
      correlation_id: get(attrs, :correlation_id),
      detail: detail,
      occurred_at: occurred_at
    }

    with {:ok, chain_present?} <- aud_chain_exists?(repo, get(attrs, :org_id)),
         {:ok, aud} <- AuditEvent.insert(repo, aud_attrs) do
      chain_attrs =
        attrs
        |> Map.put(:aud_id, aud.id)
        |> Map.put_new(:occurred_at, aud.occurred_at)
        |> commit_clamped(clamped?, aud)

      case append_chain(repo, chain_attrs, chain_present?) do
        {:ok, entry} -> {:ok, %{aud_event: aud, chain: entry}}
        {:skip, _} -> {:ok, %{aud_event: aud, chain: :skipped}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Append the chain entry. If the aud_chain table is ABSENT (host not yet migrated), skip gracefully — the
  # aud_event row still lands. The existence CHECK happens BEFORE any insert (a cheap `to_regclass` probe)
  # precisely because attempting an INSERT into a missing table inside the caller's transaction would ABORT the
  # whole transaction (Postgres 25P02) — a rescue cannot un-poison it.
  #
  # A probe that FAILED (an outage, a dropped connection) is NOT "absent": the old `rescue _ -> false` turned it
  # into a silent skip, so an audit event landed with no chain entry and the write reported success. It is now an
  # error the caller sees (reported by name + exception module), and NOTHING is written.
  defp append_chain(repo, chain_attrs, true), do: AuditChain.append(chain_attrs, repo: repo)
  defp append_chain(_repo, _chain_attrs, false), do: {:skip, :aud_chain_absent}

  defp aud_chain_exists?(repo, org_id) do
    %{rows: [[reg]]} = repo.query!("SELECT to_regclass('public.aud_chain')")
    {:ok, reg != nil}
  rescue
    e ->
      Samen.Observability.Failure.report(:audit_chain_probe, org_id, e)
      {:error, :audit_chain_unavailable}
  end

  # The chain commits what the `aud_event` row says. Normally the caller's own `occurred_at` (untouched, so hashes
  # of existing writers do not move); when the value was clamped, the clamped time and the detail that records the
  # claim — never the future value the caller supplied.
  defp commit_clamped(chain_attrs, false, _aud), do: chain_attrs

  defp commit_clamped(chain_attrs, true, aud) do
    chain_attrs
    |> Map.delete("occurred_at")
    |> Map.delete("detail")
    |> Map.put(:occurred_at, aud.occurred_at)
    |> Map.put(:detail, aud.detail)
  end

  # `occurred_at` is caller-supplied and is the PARTITION KEY of `aud_event`; the rule (past kept, future beyond the
  # skew clamped and reported, never rejected) lives in `Samen.AuditEvent.clamp_future/2`, which `AuditEvent.insert/2`
  # also applies to every other caller. It is run here as well because the chain must commit the clamped time and the
  # detail that records the claim (see `commit_clamped/3`).
  defp occurred_at_and_detail(attrs), do: AuditEvent.clamp_future(get(attrs, :occurred_at), get(attrs, :detail))

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))
  defp str(nil), do: nil
  defp str(v), do: to_string(v)
end
