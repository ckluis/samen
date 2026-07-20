defmodule Samen.Web.Billing.Dunning do
  @moduledoc """
  The framework Billing DUNNING compute surface (F7 / G8) — "who is behind on payment".
  A pure compute layer over `Samen.Web.Billing.Reads`' ALREADY-bounded, ALREADY-PII-resolved
  reads (the same relationship `Samen.Web.Operator.HealthScore` has to the operator reads).
  This module performs NO new Ash read of its own: it folds the bounded outputs of
  `Reads.invoices/2` + `Reads.subscriptions/2` into per-customer dunning rows.

  An account is IN DUNNING when it has any past-due invoice (`status in [:open, :draft]`
  with `due_date` before `now`) OR a `:past_due` / `:unpaid` subscription — the SAME
  dunning definition the kernel score uses (`Samen.Web.Operator.HealthScore.dunning?/1`),
  so the cockpit's "behind on payment" view can never disagree with the health score.

  ## Bounded BY CONSTRUCTION (A3 read-bounding)

  Every input is a bounded read: `Reads.invoices/2` and `Reads.subscriptions/2` each carry
  an explicit `limit(200)`. This module only folds those bounded lists — no row set larger
  than the sources is ever materialized, and the fold is single-pass. `rows/3` therefore
  emits at most one row per customer seen in those bounded reads. On any error the result
  is EMPTY, never unbounded.

  ## MASKING INVARIANT (🔒 vault PII)

  Each row's `:__customer__` is the record `Reads.invoices/2` / `Reads.subscriptions/2`
  ALREADY resolved through `Samen.Api.PiiResolution` on the actor's plane — tenant CLEAR,
  operator `%Masked{}` (→ ••••). This module never calls the vault, never unwraps a
  `%Masked{}`, never has a "show plaintext" branch, and never re-resolves on a different
  plane: it carries the resolver's decision through verbatim. `billing_name` / `billing_email`
  reach the LiveView only as whatever the shared chokepoint returned.

  ## Clock discipline (ONE reading — B9 carry B4-P2-1)

  `now` is captured ONCE by the caller default and threaded to every past-due
  determination, so a due date crossing "now" mid-assembly can never desync the count from
  the days-overdue. The LiveView renders these values verbatim and NEVER reads a clock.
  """

  alias Samen.Web.Billing.Reads

  @doc """
  Per-customer dunning rows for `scope`, worst first (oldest overdue, then largest amount).
  Each row: `%{customer_id, __customer__ (PII plane-resolved), past_due_count, amount_cents,
  max_days_overdue, sub_status}`. BOUNDED BY CONSTRUCTION (folds the bounded `Reads`
  outputs). `now` defaults to one reading and is threaded to every day-count.
  """
  def rows(mount, scope, now \\ DateTime.utc_now()) do
    invoices = Reads.invoices(mount, scope)
    subs = Reads.subscriptions(mount, scope)

    sub_status_by_customer =
      Enum.reduce(subs, %{}, fn s, acc ->
        Map.update(acc, s.customer_id, s.status, &worse_status(&1, s.status))
      end)

    customers_by_id = customers_by_id(invoices, subs)
    past_due_by_customer = past_due_by_customer(invoices, now)

    dunning_ids =
      MapSet.union(
        MapSet.new(Map.keys(past_due_by_customer)),
        MapSet.new(for {cid, st} <- sub_status_by_customer, st in [:past_due, :unpaid], do: cid)
      )

    dunning_ids
    |> Enum.map(fn cid ->
      pd = Map.get(past_due_by_customer, cid, %{count: 0, amount_cents: 0, max_days_overdue: 0})

      %{
        customer_id: cid,
        __customer__: Map.get(customers_by_id, cid),
        past_due_count: pd.count,
        amount_cents: pd.amount_cents,
        max_days_overdue: pd.max_days_overdue,
        sub_status: Map.get(sub_status_by_customer, cid)
      }
    end)
    |> Enum.sort_by(&{-&1.max_days_overdue, -&1.amount_cents})
  rescue
    _ -> []
  end

  @doc """
  Non-PII dunning header metrics (`accounts`, `overdue_cents`, `invoices`,
  `max_days_overdue`) — folded from the SAME bounded `rows/3` so the header can never
  disagree with the table, and every past-due determination shares the SAME `now`.
  Bounded by construction (over the bounded rows). All bounded counts/cent amounts — no PII.
  """
  def metrics(mount, scope, now \\ DateTime.utc_now()) do
    rows = rows(mount, scope, now)

    %{
      accounts: length(rows),
      overdue_cents: Enum.reduce(rows, 0, fn r, acc -> acc + r.amount_cents end),
      invoices: Enum.reduce(rows, 0, fn r, acc -> acc + r.past_due_count end),
      max_days_overdue: Enum.reduce(rows, 0, fn r, acc -> max(acc, r.max_days_overdue) end)
    }
  end

  # -- private -----------------------------------------------------------------

  # First PII-resolved customer record seen per id (invoices + subs both carry the
  # resolver's `__customer__`; the plane decision is identical on both, carried verbatim).
  defp customers_by_id(invoices, subs) do
    Enum.reduce(invoices ++ subs, %{}, fn r, acc ->
      cid = Map.get(r, :customer_id)
      cust = Map.get(r, :__customer__)

      if cid && cust && not Map.has_key?(acc, cid), do: Map.put(acc, cid, cust), else: acc
    end)
  end

  # Past-due invoice aggregate per customer: count / summed amount_due / oldest days
  # overdue. Day counts computed HERE (the reads/compute layer) so the LiveView stays
  # clock-free; `now` is the ONE reading threaded from the caller.
  defp past_due_by_customer(invoices, now) do
    invoices
    |> Enum.filter(&past_due?(&1, now))
    |> Enum.reduce(%{}, fn inv, acc ->
      days = div(max(DateTime.diff(now, inv.due_date), 0), 86_400)

      Map.update(
        acc,
        inv.customer_id,
        %{count: 1, amount_cents: inv.amount_due_cents || 0, max_days_overdue: days},
        fn pd ->
          %{
            count: pd.count + 1,
            amount_cents: pd.amount_cents + (inv.amount_due_cents || 0),
            max_days_overdue: max(pd.max_days_overdue, days)
          }
        end
      )
    end)
  end

  defp past_due?(%{status: status, due_date: %DateTime{} = due}, now)
       when status in [:open, :draft],
       do: DateTime.compare(due, now) == :lt

  defp past_due?(_, _), do: false

  # Worst-dunning subscription status wins per customer (unpaid > past_due > other).
  defp worse_status(a, b), do: if(rank(b) > rank(a), do: b, else: a)
  defp rank(:unpaid), do: 3
  defp rank(:past_due), do: 2
  defp rank(_), do: 0
end
