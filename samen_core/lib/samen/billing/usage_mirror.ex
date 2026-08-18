defmodule Samen.Billing.UsageMirror do
  @moduledoc """
  The **usage-record mirror port** `Samen.Billing.UsageReporter` reads/writes
  through (B8; T25; ADR-038 §3.1 `report_usage/2` + idempotency-key rule).

  Same "port" pattern as `Samen.Billing.Mirror` / `Samen.Billing.InvoiceMirror` /
  `Samen.Billing.CheckoutMirror` / `Samen.Billing.DunningMirror`: a HOST-injected
  module (config slot `:billing_usage_mirror`) is the ONLY thing that knows how to
  read/write the host's concrete `Usage` resource
  (`Samen.Scopes.Billing.Blueprint.define_usage/6` — already ships a `reported_at`
  column: `nil` == pending, a timestamp == reported. No new schema is needed for
  this port).

      config :samen_core, :billing_usage_mirror, {MyApp.UsageMirror, mirror_ref}

  ## Why a separate port from `Samen.Billing.Mirror`

  Usage reporting is not event-driven convergence (there is no inbound webhook
  that names a usage record) — it is a periodic BATCH pull of whatever rows are
  pending, so the read/write shape is different in kind from every other billing
  port: `read_pending/2` scans for a bounded batch instead of looking up one row
  by provider id, and `mark_reported/3` is a bulk, ALL-OR-NOTHING stamp instead of
  a single upsert.

  ## Implementations

    * `Samen.Billing.FakeUsageMirror` — in-memory, ships in lib (test infra
      precedent, mirrors `FakeMirror`/`FakeInvoiceMirror`/`FakeDunningMirror`/
      `FakeCheckoutMirror`). Proves `Samen.Billing.UsageReporter`'s
      batching/idempotency/no-data-loss properties hermetically — no DB, no
      vendor credentials.
    * The REAL, Ash-backed impl (querying the host's generated `Usage` resource,
      `reported_at IS NULL`, joined to `Subscription` for the provider ref) is a
      documented GAP (T25-G1, same shape as T21-G1/T24-G1's mirror GAPs) — it is
      explicitly OUT OF SCOPE for T25 (scope discipline: "production mirror is
      T106"). No host currently wires `:billing_usage_mirror`; until one does,
      `Samen.Billing.UsageReportWorker` is an honest, safe `:ok` no-op.
  """

  @type ref :: term()

  @type pending_record :: %{
          id: String.t(),
          metric: atom(),
          quantity: integer(),
          period_start: DateTime.t() | nil,
          period_end: DateTime.t() | nil,
          subscription_id: String.t(),
          # The provider-side ref identifying WHAT to report usage against (a
          # vendor-specific metered-billing target, e.g. a subscription-item
          # id). Resolved by the mirror impl — this port stays vendor-generic
          # (INV-4); only the adapter interprets it.
          provider_ref: String.t() | nil
        }

  @doc """
  Read up to `limit` pending (unreported — `reported_at IS NULL`) usage records,
  oldest-first (stable ordering so repeated calls under a persistent backlog make
  forward progress instead of starving older rows). Fewer than `limit` (including
  zero) is a completely normal result — NOT an error.
  """
  @callback read_pending(ref(), limit :: pos_integer()) ::
              {:ok, [pending_record()]} | {:error, term()}

  @doc """
  Mark exactly the given usage-record `ids` as reported at `reported_at`.

  MUST be all-or-nothing for the given id list: either every id is stamped or
  none are. `Samen.Billing.UsageReporter` calls this ONLY after the provider has
  confirmed the WHOLE batch was accepted — a partial marking here would silently
  create either a double-report (an id marked pending gets re-sent even though
  the provider already has it) or a drop (an id marked reported that the provider
  never actually received), so implementations must use a single atomic write
  (one `UPDATE ... WHERE id IN (...)`, one transaction), never a per-id loop that
  can fail halfway.

  Returns `{:ok, count}` — the number of rows actually stamped (lets the caller
  detect a `count != length(ids)` short-write, e.g. a row deleted between read and
  mark).
  """
  @callback mark_reported(ref(), ids :: [String.t()], reported_at :: DateTime.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
