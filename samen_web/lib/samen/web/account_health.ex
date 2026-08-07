defmodule Samen.Web.AccountHealth do
  @moduledoc """
  T77 (spec §I4 "unfair advantage") — the ONE substrate module that assembles a tenant
  org's live PORTFOLIO signals (total MRR, support load, a composite health score)
  from whichever of the `Billing`/`Support` scopes the host has mounted ALONGSIDE the
  caller's own scope (CRM today; any future consumer tomorrow — see the "both planes"
  note below).

  ## What "account" means here (load-bearing — read before touching this file; CORRECTED
  fix round 1 — the original premise below was refuted on the facts)

  **This is NOT "the org's own subscription to the platform."** `Billing.Customer` /
  `Billing.Subscription` / `Support.Ticket`, as mounted alongside a tenant's CRM scope,
  hold the ORG'S OWN CUSTOMER BASE — the shippers/carriers/accounts THIS org bills and
  supports, not what this org pays some vendor. Proof: `Samen.Web.Billing.Reads`'s own
  moduledoc ("the org reads its own customers"); `driftwood/lib/driftwood/seeds.ex`'s
  billing-customer builder comment ("the brokerage's OWN shipper billing accounts …
  the tenant's Billing page reads as its own book") and support-ticket builder comment
  ("freight disputes … referencing THIS tenant's own load numbers + carriers", handled
  by "the tenant's OWN helpdesk staff"). The SEPARATE thing — what a tenant org pays
  the SaaS platform — lives under a DIFFERENT, independently-mounted instance of this
  same Billing/Support blueprint, with its own abbrev prefixes
  (`driftwood/lib/driftwood/operator.ex`: "Driftwood's operator namespace takes fresh
  prefixes (do Identity, dp Billing, dq Support)" — a SECOND mount, not this one) and
  its own reader, `Samen.Web.Operator.Reads`/`Samen.Web.Operator.HealthScore`. This
  module NEVER reads that mount.

  So `snapshot/2` is a **PORTFOLIO view**: totals across EVERY customer/ticket this org
  itself owns (`mrr_cents` sums every active subscription across the whole book;
  `open_tickets` counts every open ticket the org's own helpdesk carries), computed
  org-wide because the substrate carries no link between a specific CRM `Company` row
  and a specific `Billing.Customer` row (no FK, no registered custom-bag anchor).
  Building that per-company link is EXPLICITLY OUT OF SCOPE for this module (a separate,
  operator-decided follow-on task) — inventing one here via name-matching would be
  exactly the fabrication CLAUDE.md's fail-honest rule forbids. **Every caller MUST
  present these numbers as portfolio/book-wide totals, never as this-specific-company's
  numbers** — see `Samen.Web.CRM.CompanyLive`'s tile labels/disclosure copy for the
  house style ("Total MRR — all customers", not "MRR").

  ## Honest absence vs a real zero vs a DEGRADED read (fix round 1, MED-3)

  `billing_available?`/`support_available?` are `false` in TWO distinct situations,
  both correctly rendered "—"/"not available" by a caller — never a fabricated `$0`/`0`:

    1. the host has not mounted that scope AT ALL (the caller's mount's host root has
       no sibling `Billing`/`Support` domain) — the FRAMEWORK-level "not configured"
       case, detected with no exception at all (`sibling_mount/4` just returns `nil`);
    2. the scope IS mounted but the underlying read GENUINELY FAILED (a DB blip, a
       policy/authorization error, …) — detected via a deliberately UNCAUGHT canary
       read at the top of `billing_snapshot/2`/`support_snapshot/2` (see their docs).
       `Samen.Web.Billing.Reads.metrics/2`/`Samen.Web.Support.Reads.metrics/2`'s own
       helpers each carry their OWN `rescue -> 0` (correct for THEIR callers — a
       dashboard tile that must never crash) — which means, once you call THEM, a
       genuine failure is INDISTINGUISHABLE from "this org truly has zero rows". The
       canary read runs the SAME query, uncaught, so a real failure raises HERE first.

  When a scope IS mounted and the read genuinely SUCCEEDS with nothing in it, the
  numbers are REAL zeros (`mrr_cents: 0`, `open_tickets: 0`, …) — a true DB aggregate,
  not a fabrication. `Billing.Reads`/`Support.Reads` themselves are UNTOUCHED by this
  fix — their existing consumers keep the exact fail-safe-empty contract they always
  had; only THIS module's own call sites gained a canary.

  ## The health composite — a DELIBERATELY narrower formula than
  `Samen.Web.Operator.HealthScore` (WS-B/ADR-019), not a duplicate of it

  `Samen.Web.Operator.HealthScore` already exists and is exactly "a substrate module
  both planes can consume" — but its 4-factor formula (billing/activity/support/
  adoption) leans on operator-only signals: G12 product-activity events, and Identity
  `Membership` seat counts. Neither is honestly available on every tenant-plane mount —
  e.g. Driftwood's OWN tenant population carries NO Identity mount at all
  (`driftwood/lib/driftwood/operator.ex`: "driftwood keeps its resource surface small" /
  "the vertical's own tenant population is the freight orgs"). Reusing that formula here
  would force a fabricated `seats: 0` ("nobody is in the product") for tenants that
  plainly have users, and a permanently-`:unknown` activity factor everywhere. Rather
  than duplicate that formula's SHAPE with fake inputs, `score/1` below scores exactly
  the two dimensions this task's substrate can support honestly on ANY tenant mount —
  `:billing` (PORTFOLIO subscription state + dunning, same dunning-cap PHILOSOPHY as
  `Operator.HealthScore`, independently expressed) and `:support` (open-ticket +
  SLA-breach load, portfolio-wide) — and is the ONE place either factor's math lives. A
  future cross-tenant consumer (T84's cockpit) composes OVER many orgs' `snapshot/2`
  results; it must not re-derive its own copy of this arithmetic. (Cross-referenced from
  `docs/adr/ADR-044-fleet-cockpit.md` §5.3 and `Samen.Web.Operator.HealthScore`'s own
  moduledoc — three divergent health formulas is the risk being closed, fix round 1.)

  Each factor is `1.0` (best) down to `0.0` (worst), or `:unknown` when its scope isn't
  mounted at all — an `:unknown` factor contributes `0` and the OTHER factor's weight
  renormalizes to fill 100%, so the composite still computes with whichever signal
  exists (mirrors `Operator.HealthScore`'s own `:unknown`-renormalization pattern,
  AC-G17-7). The composite itself is `nil`/`band: :unknown` ONLY when BOTH scopes are
  absent — there is nothing left to score, not even a partial one.

  ## Fix round 1, MED-2 — the billing factor uses the WORST subscription across the
  WHOLE book, never a cherry-picked "primary" one

  A book with 5 active subscriptions and 1 past-due one is NOT "active and current" —
  `billing_snapshot/2` computes `subscription_status` as the WORST status across EVERY
  subscription the org holds (`worst_subscription_status/1`), not the best/"primary"
  one a prior version preferred. The billing factor's explanation string is written to
  match: it describes the WORST state on file, never implies every customer is fine
  when even one is not.

  ## No PII (verified refutable in `crm_account_health_test.exs`)

  Every field this module reads/returns is a bounded count, cent amount, enum, or
  timestamp — `Subscription.status`, `Invoice.status/amount_due_cents/due_date`,
  `Ticket.status/priority/breached`. None of these are vault-routed (the Billing/Support
  blueprints carry PII only on `Customer.billing_name/billing_email` and
  `Message.body` — neither is read here). This module never touches the PII resolver
  or the vault directly — there is nothing on this path for either to resolve.
  """

  require Logger

  alias Samen.Web.Mount

  defstruct score: nil, band: :unknown, factors: []

  @type factor :: %{name: atom(), weight: number(), value: float() | :unknown, contribution: float(), explanation: String.t()}
  @type t :: %__MODULE__{score: 0..100 | nil, band: :healthy | :watch | :at_risk | :critical | :unknown, factors: [factor()]}

  # Weights sum to 100 over the two tenant-honest dimensions (billing leads — it is the
  # money relationship; support is the secondary friction signal).
  @weights %{billing: 60, support: 40}

  # Same dunning-cap PHILOSOPHY as `Operator.HealthScore` (a billing dimension in
  # dunning can never rate above this, however recent/small the overdue amount) —
  # independently expressed here (see moduledoc "not a duplicate").
  @dunning_cap 0.5

  @band_healthy 85
  @band_watch 65
  @band_at_risk 40

  @factor_healthy 0.85
  @factor_watch 0.6
  @factor_at_risk 0.35

  @doc """
  Assemble ONE tenant org's PORTFOLIO snapshot (totals across this org's OWN customer/
  ticket book — see the moduledoc's corrected "what account means" section). `mount` is
  ANY host-mounted `Samen.Web.Mount` whose namespace's host root ALSO carries
  `Billing`/`Support` siblings (CRM's mount today); `scope` is that SAME org's
  `Samen.Web.Mount.scope/2`.

  Returns:

      %{
        billing_available?: boolean(),
        mrr_cents: non_neg_integer() | nil,
        active_subs: non_neg_integer() | nil,
        subscription_status: atom() | nil,
        past_due: %{count:, amount_cents:, max_days_overdue:} | nil,
        support_available?: boolean(),
        open_tickets: non_neg_integer() | nil,
        breaching_sla: non_neg_integer() | nil,
        solved_this_week: non_neg_integer() | nil,
        health: %__MODULE__{} | nil
      }

  `mrr_cents`/`open_tickets`/etc are `nil` exactly when their `_available?` flag is
  `false` — the honest-absence contract callers must render as "—", never as `0`.
  """
  def snapshot(mount, scope) do
    billing = billing_snapshot(sibling_mount(mount, :billing, ["Billing", "BillingScope"], Customer), scope)
    support = support_snapshot(sibling_mount(mount, :support, ["Support", "SupportScope"], Ticket), scope)

    %{
      billing_available?: billing != nil,
      mrr_cents: billing && billing.mrr_cents,
      active_subs: billing && billing.active_subs,
      subscription_status: billing && billing.subscription_status,
      past_due: billing && billing.past_due,
      support_available?: support != nil,
      open_tickets: support && support.open_tickets,
      breaching_sla: support && support.breaching_sla,
      solved_this_week: support && support.solved_this_week,
      health: score(%{billing: billing, support: support})
    }
  rescue
    e ->
      # Fix round 1, LOW: `billing_snapshot/2`/`support_snapshot/2` already convert
      # every genuine read failure into an honest `nil` (with their OWN loud log —
      # see their docs); reaching THIS rescue means something else broke (e.g.
      # `sibling_mount/4`'s own probe, or `score/1` itself) — log it loudly so a REAL
      # bug is never silently indistinguishable from "this host just doesn't mount
      # Billing/Support" in the returned shape (which, by necessity, looks the same
      # either way to the caller — the distinction lives in the logs, not the return
      # value, exactly like `billing_snapshot/2`'s canary rescue below).
      Logger.warning(
        "Samen.Web.AccountHealth.snapshot/2: unexpected crash assembling the portfolio snapshot (NOT necessarily \"scope not mounted\" — check this trace): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      %{
        billing_available?: false,
        mrr_cents: nil,
        active_subs: nil,
        subscription_status: nil,
        past_due: nil,
        support_available?: false,
        open_tickets: nil,
        breaching_sla: nil,
        solved_this_week: nil,
        health: nil
      }
  end

  @doc """
  The pure composite (no I/O, no clock) — `%{billing: nil | map, support: nil | map}`
  in, `%__MODULE__{}` out. `nil` for either key means that scope is not mounted at all
  (the `:unknown` factor, renormalizing); a present map with real-but-empty values
  (e.g. `subscription_status: nil` because the org has no subscription YET) scores a
  real low value, not `:unknown` — the scope exists, it just has nothing good to report.
  """
  def score(%{billing: billing, support: support}) do
    factors = [billing_factor(billing), support_factor(support)]
    known = Enum.reject(factors, &(&1.value == :unknown))

    if known == [] do
      %__MODULE__{score: nil, band: :unknown, factors: factors}
    else
      known_weight = Enum.reduce(known, 0, &(&1.weight + &2))

      factors =
        Enum.map(factors, fn
          %{value: :unknown} = f -> Map.put(f, :contribution, 0.0)
          f -> Map.put(f, :contribution, Float.round(f.value * f.weight / known_weight * 100, 1))
        end)

      score =
        factors
        |> Enum.reduce(0.0, &(&1.contribution + &2))
        |> round()
        |> min(100)
        |> max(0)

      %__MODULE__{score: score, band: band_of(score, factors), factors: factors}
    end
  end

  @doc "Whether ANY billing/support scope contributed a real (known) factor — vs a fully :unknown composite."
  def known?(%__MODULE__{score: score}), do: is_integer(score)

  @doc "The band of ONE dimension (`:unknown | :healthy | :watch | :at_risk | :critical`)."
  def factor_band(%{value: :unknown}), do: :unknown
  def factor_band(%{value: v}) when v >= @factor_healthy, do: :healthy
  def factor_band(%{value: v}) when v >= @factor_watch, do: :watch
  def factor_band(%{value: v}) when v >= @factor_at_risk, do: :at_risk
  def factor_band(%{}), do: :critical

  @doc "The bounded composite bands, best -> worst, PLUS `:unknown` (neither scope mounted)."
  def bands, do: [:healthy, :watch, :at_risk, :critical, :unknown]

  # -- composite band (threshold + the dunning ceiling, mirrored from HealthScore) -----

  defp band_of(score, factors) do
    base =
      cond do
        score >= @band_healthy -> :healthy
        score >= @band_watch -> :watch
        score >= @band_at_risk -> :at_risk
        true -> :critical
      end

    billing = Enum.find(factors, &(&1.name == :billing))

    if base == :healthy and factor_band(billing) in [:at_risk, :critical] do
      :watch
    else
      base
    end
  end

  # -- the two factors ------------------------------------------------------------

  defp billing_factor(nil) do
    %{
      name: :billing,
      weight: @weights.billing,
      value: :unknown,
      contribution: 0.0,
      explanation: "Billing is not mounted for this app — excluded from the composite; the remaining weight renormalizes"
    }
  end

  # `status` here is the WORST subscription status across the org's WHOLE customer book
  # (`worst_subscription_status/1`, fix round 1 MED-2) — never a cherry-picked "primary"
  # (best) subscription. The explanation strings below are written to match: they
  # describe the worst state on file, never imply every customer is fine when even one
  # is not.
  defp billing_factor(%{subscription_status: status, past_due: pd}) do
    {value, explanation} =
      cond do
        is_nil(status) ->
          {0.0, "no subscriptions on file across this org's customer book — nothing keeps it current"}

        status in [:cancelled, :canceled] ->
          {0.0, "at least one customer subscription is cancelled — treat as churn risk in this book"}

        dunning?(status, pd) ->
          {dunning_value(pd), dunning_explanation(pd, status)}

        status in [:active, :trialing] ->
          {1.0, "the worst subscription state on file is '#{status}' — current, no past-due invoices anywhere in the book"}

        true ->
          {0.25, "at least one customer subscription is in an unrecognized state #{inspect(status)}"}
      end

    %{name: :billing, weight: @weights.billing, value: clamp01(value), contribution: 0.0, explanation: explanation}
  end

  defp dunning?(status, %{count: count}), do: count > 0 or status in [:past_due, :unpaid]

  defp dunning_explanation(pd, status) do
    status_note =
      if status in [:past_due, :unpaid], do: "at least one customer subscription is #{status}; ", else: ""

    "this book is in dunning: #{status_note}#{pd.count} past-due invoice(s) across the org's customers, " <>
      "#{cents(pd.amount_cents)} overdue, oldest #{pd.max_days_overdue} day(s) past due — capped below the top band until every invoice clears"
  end

  defp dunning_value(pd) do
    days_penalty = min(pd.max_days_overdue, 90) / 90 * 0.35
    count_penalty = min(max(pd.count - 1, 0), 5) * 0.03

    (@dunning_cap - days_penalty - count_penalty)
    |> max(0.02)
    |> min(@dunning_cap)
  end

  defp support_factor(nil) do
    %{
      name: :support,
      weight: @weights.support,
      value: :unknown,
      contribution: 0.0,
      explanation: "Support is not mounted for this app — excluded from the composite; the remaining weight renormalizes"
    }
  end

  defp support_factor(%{open_tickets: open, breaching_sla: breaching}) do
    value = clamp01(1.0 - 0.1 * open - 0.2 * breaching)

    explanation =
      case {open, breaching} do
        {0, 0} -> "no open support tickets across this org's customer book"
        {o, 0} -> "#{o} open support ticket(s) across the book, none breaching SLA"
        {o, b} -> "#{o} open support ticket(s) across the book, #{b} breaching SLA"
      end

    %{name: :support, weight: @weights.support, value: value, contribution: 0.0, explanation: explanation}
  end

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> then(&(&1 / 1))
  defp cents(c), do: "$#{:erlang.float_to_binary(c / 100, decimals: 2)}"

  # -- billing/support read assembly (delegates to the EXISTING Billing/Support Reads
  # modules — zero duplicated aggregate logic, A3 read-bounding inherited from them) ---

  defp billing_snapshot(nil, _scope), do: nil

  defp billing_snapshot(billing_mount, scope) do
    # Fix round 1, MED-3 — a CANARY read, deliberately UNCAUGHT, run before any of
    # `Billing.Reads`'s own helpers (whose `rescue -> 0` swallow a genuine failure into
    # a real-looking zero for THEIR callers — correct for a dashboard tile that must
    # never crash, WRONG once this function treated that zero as fact). This runs the
    # SAME query `metrics/2` runs internally for `active_subs`, with nothing here to
    # catch it — a real failure propagates to THIS function's own `rescue` below
    # instead of masquerading as "$0.00, no subscription on file". `Billing.Reads`
    # itself is UNTOUCHED — its existing consumers keep their current, correct-for-them
    # fail-safe-empty contract; only this call site gained the canary.
    Ash.count!(Mount.resource(billing_mount, Customer), scope: scope)

    metrics = Samen.Web.Billing.Reads.metrics(billing_mount, scope)
    subs = Samen.Web.Billing.Reads.subscriptions(billing_mount, scope)
    invoices = Samen.Web.Billing.Reads.invoices(billing_mount, scope)

    now = DateTime.utc_now()

    %{
      mrr_cents: metrics.mrr_cents,
      active_subs: metrics.active_subs,
      # Fix round 1, MED-2 — the WORST status across EVERY subscription this org
      # holds, never a cherry-picked "primary" (best) one.
      subscription_status: worst_subscription_status(subs),
      past_due: past_due_summary(invoices, now)
    }
  rescue
    e ->
      Logger.warning(
        "Samen.Web.AccountHealth.billing_snapshot/2: read failed, reporting honest absence, never a fabricated $0 (fix round 1 MED-3): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # Fix round 1, MED-2 — worst-of-N: an org with 5 active subscriptions and 1 past-due
  # one is NOT "active and current". Ranks every subscription's status by severity
  # (cancelled/canceled worst, then unpaid, then past_due, then any unrecognized status,
  # then active/trialing best) and returns the WORST one on file — `nil` only when the
  # book holds NO subscriptions at all. Ties (e.g. two equally-severe statuses) resolve
  # to whichever the underlying read returned first — irrelevant, since same-severity
  # statuses score identically downstream.
  @status_severity %{cancelled: 0, canceled: 0, unpaid: 1, past_due: 2, active: 4, trialing: 4}
  @unrecognized_status_severity 3

  defp worst_subscription_status([]), do: nil

  defp worst_subscription_status(subs) do
    subs
    |> Enum.map(& &1.status)
    |> Enum.min_by(&Map.get(@status_severity, &1, @unrecognized_status_severity))
  end

  defp past_due_summary(invoices, now) do
    invoices
    |> Enum.filter(&past_due?(&1, now))
    |> Enum.reduce(%{count: 0, amount_cents: 0, max_days_overdue: 0}, fn inv, acc ->
      days = div(max(DateTime.diff(now, inv.due_date), 0), 86_400)

      %{
        count: acc.count + 1,
        amount_cents: acc.amount_cents + (inv.amount_due_cents || 0),
        max_days_overdue: max(acc.max_days_overdue, days)
      }
    end)
  end

  # Same "past due" definition as `Samen.Web.Operator.Reads` (ADR-019): status in
  # [:open, :draft] AND the due date has passed. Kept identical on purpose — an
  # invoice is not past-due-on-the-operator-plane-but-current-on-the-tenant-plane.
  defp past_due?(%{status: status, due_date: %DateTime{} = due}, now) when status in [:open, :draft],
    do: DateTime.compare(due, now) == :lt

  defp past_due?(_, _), do: false

  defp support_snapshot(nil, _scope), do: nil

  defp support_snapshot(support_mount, scope) do
    # Fix round 1, MED-3 — the SAME canary discipline as `billing_snapshot/2` (see its
    # doc): `Support.Reads.metrics/2`'s helpers carry the identical `rescue -> 0`
    # shape, so this uncaught canary is what lets a genuine failure surface as honest
    # absence here instead of a fabricated "0 open tickets".
    Ash.count!(Mount.resource(support_mount, Ticket), scope: scope)

    metrics = Samen.Web.Support.Reads.metrics(support_mount, scope)

    %{
      open_tickets: metrics.open_tickets,
      breaching_sla: metrics.breaching_sla,
      solved_this_week: metrics.solved_this_week
    }
  rescue
    e ->
      Logger.warning(
        "Samen.Web.AccountHealth.support_snapshot/2: read failed, reporting honest absence, never a fabricated 0 (fix round 1 MED-3): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # -- host-root bridge (the SAME derivation `Samen.Web.CRM.Reads.work_task_resource/1`
  # / `mailbox_message_resource/1` use): drop the caller mount's namespace's LAST
  # segment to reach the host root, then try each candidate scope-segment name (hosts
  # vary: "Billing"/"Support" on driftwood/pawchart/samen_web-test, "BillingScope"/
  # "SupportScope" on demo). `probe_name` is a resource this scope MUST define
  # (`Customer` / `Ticket`) — used ONLY to confirm the candidate is a live, compiled
  # Ash resource; never queried for this check. `nil` when no host root exists at all
  # (the CRM mount's namespace has no dot) or neither candidate compiles — the honest
  # "this scope is not mounted for this host" case.
  defp sibling_mount(%Mount{namespace: ns} = mount, scope_kind, segments, probe_name) do
    root = ns |> Module.split() |> Enum.drop(-1)

    Enum.find_value(segments, fn seg ->
      candidate = Module.concat(root ++ [seg])

      if resource?(Module.concat(candidate, probe_name)) do
        %{mount | scope_kind: scope_kind, namespace: candidate, domain: candidate}
      end
    end)
  rescue
    _ -> nil
  end

  defp resource?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :spark_is, 0) and Ash.Resource.Info.resource?(mod)
  rescue
    _ -> false
  end
end
