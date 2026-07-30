defmodule Samen.Approvals.Handler do
  @moduledoc """
  The E3 approval **handler** behaviour (ADR-040 §4.4, Face 1 — the handler registry
  for kernel/non-Ash clients; reveal grants adopt this in T35).

  A handler runs **inside the decision transaction** (§4.3): `Samen.Approvals.approve/3`
  transitions the `Approval` `pending → approved` (machine-guarded — the exactly-once
  mechanism), then invokes `on_approve/2` in the SAME transaction, then writes the
  governance audit. If `on_approve/2` returns `{:error, _}` the whole transaction rolls
  back: the approval stays `pending`, no audit lands, and — for a client like reveal —
  the grant insert + auto-revoke enqueue that `on_approve/2` performed roll back with it.
  This is what preserves the reveal same-tx guarantee when reveal becomes a client.

  ## The no-persisted-inputs rule (binding, ADR-040 §4.4)

  The engine NEVER stores the action's inputs. A handler re-derives everything it needs
  from **governed domain state** — the `subject_ref` on the approval points at the domain
  record that carries the intent (vault-routed where PII). `on_approve/2` loads that record
  and acts on it; it must not depend on any raw input having been stashed on the approval
  row. An approval row is `{org_id, kind, subject_ref, parties, reason, state}` — nothing
  else (INV-1: no plaintext PII / `vt_*` token ever lands in an approval row).

  ## Context

  `ctx` carries `%{approval: struct(), actor: term(), repo: module(), opts: keyword()}`.
  `actor` is the DECIDING actor (the approver); a Gate-style handler that must run the
  approved work "as the requester" reconstructs the requester principal from
  `approval.requested_by` / `approval.org_id` (the requester consented by requesting; the
  approver only adds second-party consent — never privilege — ADR-040 §4.4, §12).
  """

  @typedoc "The decision context handed to a handler, all inside the decision transaction."
  @type ctx :: %{
          required(:approval) => struct(),
          required(:actor) => term(),
          required(:repo) => module(),
          required(:opts) => keyword()
        }

  @doc """
  Run the client's approved work inside the decision transaction. Return `{:ok, meta}`
  (meta is a bounded, token-only map merged into the decision result) or `{:error, term}`
  to roll the whole decision back (approval stays `pending`).
  """
  @callback on_approve(approval :: struct(), ctx :: ctx()) ::
              {:ok, meta :: map()} | {:error, term()}

  @doc """
  Optional symmetric hook for a rejection (default: a no-op). Runs inside the
  `reject/3` transaction; `{:error, term}` rolls the rejection back.
  """
  @callback on_reject(approval :: struct(), ctx :: ctx()) :: :ok | {:error, term()}

  @optional_callbacks on_reject: 2
end
