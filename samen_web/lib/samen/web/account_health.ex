defmodule Samen.Web.AccountHealth do
  @moduledoc """
  T77 (spec §I4 "unfair advantage") — the ONE substrate module that assembles a tenant
  org's live PORTFOLIO signals (total MRR, support load, a composite health score)
  from whichever of the `Billing`/`Support` scopes the host has mounted ALONGSIDE the
  caller's own scope (CRM today; any future consumer tomorrow — see the "both planes"
  note below). **T160 (below) additionally provides the REAL per-account seam** —
  `snapshot_for_company/3` — which is what actually delivers spec §I4's "unfair
  advantage" (a rep opens Acme's CRM page and sees ACME's own MRR/health).

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
  `open_tickets` counts every open ticket the org's own helpdesk carries). **Every
  caller MUST present these numbers as portfolio/book-wide totals, never as this-
  specific-company's numbers** — see `Samen.Web.CRM.CompanyLive`'s PORTFOLIO panel
  copy for the house style ("Total MRR — all customers", not "MRR").

  ## T160 — the REAL per-account seam (spec §I4 completion, operator ruling 2026-08-06)

  T77 correctly refused to fabricate a per-company number by name-matching — there was
  no LINK between a specific `Company` row and a specific `Billing.Customer` row.
  `Samen.CRM.AccountLink` (samen_core) now IS that link: a registered Tier-1 custom-
  field anchor (`Company.custom["billing_customer_id"]`, zero migration, ADR-041
  `crm_refs` precedent) with a fail-closed vaulted-domain-match fallback (T74
  `Samen.Mailbox.Match`'s shape, verbatim). `snapshot_for_company/3` resolves a SPECIFIC
  `Company` through that link and returns THAT customer's own MRR/subscription-status/
  dunning — honest absence (`link_status: :unlinked`, `billing_available?: false`) when
  no confident link exists, NEVER a book-wide number rendered under a specific
  company's name (the T77 defect this closes), never a fabricated `$0` either.

  **Support stays portfolio-only per company** — `Support.Ticket` carries NO structural
  link to a `Company`/`Billing.Customer` in this substrate (verified: no
  `customer_id`/`company_id` attribute, no typed `belongs_to`, `Conversation.sender_id`
  is a bare untyped `:uuid` — `samen_core/lib/samen/scopes/support/blueprint.ex`).
  Building that link would need a NEW attribute (a migration) — out of T160's
  zero-migration scope. `snapshot_for_company/3` is therefore honest about this: it
  ALWAYS reports `support_available?: false` with a distinct reason from "not
  configured" (see `Samen.Web.CRM.CompanyLive`'s per-company support tile copy);
  org-wide support load remains available via `snapshot/2`'s PORTFOLIO view.

  ## Honest absence vs a real zero vs a DEGRADED read (fix round 1, MED-3)

  `billing_available?`/`support_available?` are `false` in TWO distinct situations,
  both correctly rendered "—"/"not available" by a caller — never a fabricated `$0`/`0`:

    1. the host has not mounted that scope AT ALL (the caller's mount's host root has
       no sibling `Billing`/`Support` domain) — the FRAMEWORK-level "not configured"
       case, detected with no exception at all (`sibling_mount/4` just returns `nil`);
    2. the scope IS mounted but the underlying read GENUINELY FAILED (a DB blip, a
       policy/authorization error, …) — detected via a deliberately UNCAUGHT canary
       read at the top of `billing_snapshot/2`/`support_snapshot/2` (see their docs).
       `Billing.Reads`'s own helpers each carry their OWN `rescue -> 0` (correct for
       THEIR callers — a dashboard tile that must never crash) — which means, once you
       call THEM, a genuine failure is INDISTINGUISHABLE from "this org truly has zero
       rows". The canary read runs the SAME query, uncaught, so a real failure raises
       HERE first. `customer_billing_snapshot/3` (T160) needs no separate canary — its
       own reads never swallow internally, so its own `rescue` IS the canary (see its doc).

  For `snapshot_for_company/3` there is a THIRD honest-absence case, distinct from
  both of the above: the scope IS mounted and every read genuinely succeeds, but this
  specific `Company` has no confident link (`Samen.CRM.AccountLink.resolve/2` returns
  `{:error, :not_linked}`) — `link_status: :unlinked`. This is not a read failure; it
  is an honest "nothing to show yet" for THIS company, rendered identically to the
  other two absence cases (never a fabricated number) but distinguishable via
  `link_status` for a caller that wants to offer "link this company" UI.

  When a scope IS mounted and the read genuinely SUCCEEDS with nothing in it, the
  numbers are REAL zeros (`mrr_cents: 0`, `open_tickets: 0`, …) — a true DB aggregate,
  not a fabrication.

  ## The health composite — a DELIBERATELY narrower formula than
  `Samen.Web.Operator.HealthScore` (WS-B/ADR-019), not a duplicate of it

  `Samen.Web.Operator.HealthScore` already exists and is exactly "a substrate module
  both planes can consume" — but its 4-factor formula (billing/activity/support/
  adoption) leans on operator-only signals: G12 product-activity events, and Identity
  `Membership` seat counts. Neither is honestly available on every tenant-plane mount —
  e.g. Driftwood's OWN tenant population carries NO Identity mount at all. Rather than
  duplicate that formula's SHAPE with fake inputs, `score/1` below scores exactly the
  two dimensions this task's substrate can support honestly on ANY tenant mount —
  `:billing` (subscription state + dunning) and `:support` (open-ticket + SLA-breach
  load) — and is the ONE place either factor's math lives (cross-referenced from
  `docs/adr/ADR-044-fleet-cockpit.md` §5.3 and `Samen.Web.Operator.HealthScore`'s own
  moduledoc — three divergent health formulas is the risk being closed).

  Each factor is `1.0` (best) down to `0.0` (worst), or `:unknown` when its scope isn't
  mounted at all — an `:unknown` factor contributes `0` and the OTHER factor's weight
  renormalizes to fill 100%. The composite itself is `nil`/`band: :unknown` ONLY when
  BOTH scopes are absent — there is nothing left to score, not even a partial one.

  ## Worst-of-N vs score-by-SHARE (fix round 1 MED-2, T160 P3)

  `billing_factor/1` takes ONE `subscription_status` (the worst across every
  subscription considered) plus an OPTIONAL `:scoring_status`/`:share` pair:

    * **Per-account** (`snapshot_for_company/3`, N = one customer's OWN
      subscriptions) — `:scoring_status` is absent, so it defaults to
      `subscription_status` itself: plain worst-of-N. This is CORRECT BY
      CONSTRUCTION for a single account (T160 P3 disposition) — a customer with 5
      subscriptions and 1 cancelled genuinely has a cancelled product on file.

    * **Portfolio** (`snapshot/2`, N = every subscription across the WHOLE book) —
      `billing_snapshot/2` supplies BOTH `subscription_status` (the TRUE worst across
      EVERY subscription, including cancelled — still shown as-is, honest "worst
      status in book" text) AND `:scoring_status` (the worst among the LIVE,
      non-cancelled subset) plus `:share` (DB-aggregate counts). Cancelled
      subscriptions are terminal history in a provider mirror, so ONE cancelled
      subscription among nine healthy ones must not saturate the whole book's score
      at the floor (T77 delta-verdict D4b, punch item P3) — `:scoring_status` skips
      cancelled entirely UNLESS every subscription on file is cancelled/absent, in
      which case the churn is surfaced honestly (`share.cancelled` count in the
      copy) and the factor still floors to `0.0` (a book with ZERO live customers
      genuinely IS at risk).

  ## Book-wide DB aggregates, not a 200-row bound (T160 P4)

  T77's delta round computed `subscription_status`/`past_due` from
  `Billing.Reads.subscriptions/2`/`invoices/2` — each capped at 200 rows — while the
  copy claimed book-WIDE completeness ("no past-due invoices anywhere in the book"),
  provably false past the 200th row (delta finding D6). `worst_status_via_db/2` and
  `past_due_aggregate/3` below replace that with `Ash.count!`/`Ash.exists?`-shaped
  bounded existence/aggregate queries (mirroring `compute_mrr/2`'s own DB-aggregate
  precedent in `Samen.Web.Billing.Reads`) — EXACT for any book size, not capped at 200.
  Per-account tiles never needed the bound in the first place (one customer's own
  subscriptions), but now use the SAME exact helpers for consistency.

  ## `:inactive` (T160 P5) + dunning copy (T160 P6)

  `:inactive` is a DECLARED `Billing.Subscription` status (the blueprint's `one_of`)
  that T77 left unranked, so it fell to "an unrecognized state" — factually wrong
  about the schema. It now gets its OWN branch (`billing_factor/1`): a neutral 0.5,
  not a red flag, not "unrecognized". `dunning_explanation/2` no longer prints a
  hollow "0 past-due invoice(s) … $0.00 overdue" when dunning is purely
  SUBSCRIPTION-status-driven (no overdue invoice rows yet) — the invoice clause is
  omitted entirely when `past_due.count == 0`.

  ## No PII (verified refutable in `crm_account_health_test.exs`)

  Every field this module reads/returns is a bounded count, cent amount, enum, or
  timestamp — `Subscription.status`, `Invoice.status/amount_due_cents/due_date`,
  `Ticket.status/priority/breached`, `Company.domain` (plain, non-PII). The ONE PII
  field this module's T160 half touches is `Billing.Customer.billing_email` (vault
  `:pii_email`) — read EXCLUSIVELY through `Samen.CRM.AccountLink`'s own call into the
  shared PII resolver (tenant plane), never directly, never unwrapped, never returned
  to a caller (only a boolean match outcome crosses back). This module itself never
  calls the PII resolver or the vault directly (see `crm_account_health_test.exs`'s
  source-grep anti-tautology proof, which greps THIS file, not `AccountLink`'s).
  """

  require Ash.Query
  require Logger

  alias Samen.CRM.AccountLink
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

  # T160 P4/P5 — the ordered severity tiers a subscription's status is checked against,
  # worst-first (`worst_status_via_db/2` below). Encodes the SAME ranking T77's
  # `@status_severity` map did (`:inactive` now included, P5), just via an ordered
  # existence-check cascade instead of an in-memory `Enum.min_by` over a bounded read
  # (T160 P4 — see the moduledoc). `:cancelled`/`:canceled` are the worst (§tier list
  # order); anything not named here (including `:active`/`:trialing`, always checked
  # last) is either "unrecognized" (an atom outside this whole list, checked after
  # every named tier) or the best case.
  @severity_tiers [
    cancelled: [:cancelled, :canceled],
    unpaid: [:unpaid],
    past_due: [:past_due],
    inactive: [:inactive]
  ]

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
  T160 (spec §I4 completion) — ONE CRM `Company`'s OWN snapshot, resolved through its
  linked `Billing.Customer` via `Samen.CRM.AccountLink` (registered anchor, authoritative;
  fail-closed vaulted-domain-match fallback otherwise). `mount`/`scope` are the CALLER's
  (CRM) mount/scope — exactly the same pair `snapshot/2` takes; `company` is the loaded
  `Company` struct (must carry `:custom` and `:domain` — `Reads.get_company/3` selects
  both).

  Returns the SAME shape as `snapshot/2` plus `link_status` (`:anchor | :domain |
  :unlinked`) and `billing_customer_id` (the resolved customer's id, or `nil`).
  `support_available?` is ALWAYS `false` here (see the moduledoc — Support carries no
  per-account link in this substrate); `snapshot/2` remains the org-wide support source.

  Honest absence (`link_status: :unlinked`, every numeric field `nil`) when: the
  Billing scope isn't mounted at all, the company has no confident link (no anchor +
  no single confident domain match), OR the underlying read genuinely fails — NEVER a
  book-wide number under this company's name, NEVER a fabricated `$0`.
  """
  @spec snapshot_for_company(Mount.t(), Samen.Scope.t() | nil, map()) :: map()
  def snapshot_for_company(mount, scope, company) do
    billing_mount = sibling_mount(mount, :billing, ["Billing", "BillingScope"], Customer)

    case resolve_link(billing_mount, scope_org_id(scope), mount.repo, company) do
      {:ok, customer, source} ->
        billing = customer_billing_snapshot(billing_mount, scope, customer.id)

        %{
          link_status: source,
          billing_customer_id: customer.id,
          billing_available?: billing != nil,
          mrr_cents: billing && billing.mrr_cents,
          active_subs: billing && billing.active_subs,
          subscription_status: billing && billing.subscription_status,
          past_due: billing && billing.past_due,
          support_available?: false,
          open_tickets: nil,
          breaching_sla: nil,
          solved_this_week: nil,
          health: score(%{billing: billing, support: nil})
        }

      {:error, :not_linked} ->
        unlinked_snapshot()
    end
  rescue
    e ->
      Logger.warning(
        "Samen.Web.AccountHealth.snapshot_for_company/3: unexpected crash resolving/reading the per-company snapshot (NOT necessarily \"not linked\" — check this trace): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      unlinked_snapshot()
  end

  defp unlinked_snapshot do
    %{
      link_status: :unlinked,
      billing_customer_id: nil,
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

  defp resolve_link(nil, _org_id, _repo, _company), do: {:error, :not_linked}
  defp resolve_link(_billing_mount, nil, _repo, _company), do: {:error, :not_linked}

  defp resolve_link(billing_mount, org_id, repo, company) do
    config = %AccountLink.Config{
      org_id: org_id,
      repo: repo,
      customer_resource: Mount.resource(billing_mount, Customer)
    }

    AccountLink.resolve(company, config)
  end

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp scope_org_id(_scope), do: nil

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

  # `subscription_status` is the TRUE worst-of-N (honest display text — see the
  # moduledoc's "Worst-of-N vs score-by-SHARE" section). `scoring_status` (T160 P3),
  # when present, DRIVES the value instead: absent -> defaults to `subscription_status`
  # itself (plain worst-of-N — the per-account, correct-by-construction path);
  # present (portfolio only) -> the worst status among the LIVE (non-cancelled)
  # subscriptions, so one historical cancelled subscription can never alone floor an
  # otherwise-healthy book. `share.cancelled` (portfolio only; absent/0 for per-account)
  # is surfaced in the copy either way — churn is disclosed, never hidden, just no
  # longer allowed to zero a book that still has a live customer base.
  defp billing_factor(%{subscription_status: status, past_due: pd} = input) do
    scoring_status = Map.get(input, :scoring_status, status)
    cancelled_count = get_in(input, [:share, :cancelled]) || 0

    {value, explanation} =
      cond do
        is_nil(scoring_status) and cancelled_count > 0 ->
          {0.0, "every subscription on file (#{cancelled_count}) is cancelled — full churn, no active book left"}

        is_nil(scoring_status) ->
          {0.0, "no subscriptions on file across this org's customer book — nothing keeps it current"}

        scoring_status in [:cancelled, :canceled] ->
          {0.0, "at least one customer subscription is cancelled — treat as churn risk in this book"}

        dunning?(scoring_status, pd) ->
          {dunning_value(pd), dunning_explanation(scoring_status, pd)}

        scoring_status in [:active, :trialing] ->
          {1.0, active_explanation(scoring_status, cancelled_count)}

        # T160 P5 — `:inactive` is a DECLARED blueprint status (paused, not currently
        # billing) — a neutral signal, never "unrecognized".
        scoring_status == :inactive ->
          {0.5, "at least one customer subscription is inactive (paused, not currently billing) — treated as neutral, not a red flag"}

        true ->
          {0.25, "at least one customer subscription is in an unrecognized state #{inspect(scoring_status)}"}
      end

    %{name: :billing, weight: @weights.billing, value: clamp01(value), contribution: 0.0, explanation: explanation}
  end

  defp dunning?(status, %{count: count}), do: count > 0 or status in [:past_due, :unpaid]

  # T160 P6 — the invoice clause is OMITTED entirely when there is no overdue invoice
  # evidence (`pd.count == 0`, a purely subscription-status-driven dunning signal) —
  # never "0 past-due invoice(s) … $0.00 overdue", the hollow-but-technically-true copy
  # T77's delta round shipped.
  defp dunning_explanation(status, pd) do
    status_note = if status in [:past_due, :unpaid], do: "at least one customer subscription is #{status}"
    invoice_note = if pd.count > 0, do: invoice_overdue_note(pd)

    body =
      case Enum.reject([status_note, invoice_note], &is_nil/1) do
        [] -> "billing is in dunning"
        parts -> Enum.join(parts, "; ")
      end

    "this book is in dunning: #{body}" <> if(invoice_note, do: " — capped below the top band until every invoice clears", else: "")
  end

  defp invoice_overdue_note(pd) do
    "#{pd.count} past-due invoice(s) across the org's customers, #{cents(pd.amount_cents)} overdue, " <>
      "oldest #{pd.max_days_overdue} day(s) past due"
  end

  defp dunning_value(pd) do
    days_penalty = min(pd.max_days_overdue, 90) / 90 * 0.35
    count_penalty = min(max(pd.count - 1, 0), 5) * 0.03

    (@dunning_cap - days_penalty - count_penalty)
    |> max(0.02)
    |> min(@dunning_cap)
  end

  defp active_explanation(scoring_status, 0),
    do: "the worst subscription state on file is '#{scoring_status}' — current, no past-due invoices anywhere in the book"

  defp active_explanation(scoring_status, cancelled_count) do
    "the worst LIVE subscription state on file is '#{scoring_status}' — current; #{cancelled_count} cancelled subscription(s) " <>
      "excluded from the floor as historical churn, not counted against this score"
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
    # never crash, WRONG once this function treated that zero as fact). `Billing.Reads`
    # itself is UNTOUCHED — its existing consumers keep their current, correct-for-them
    # fail-safe-empty contract; only this call site gained the canary.
    Ash.count!(Mount.resource(billing_mount, Customer), scope: scope)

    metrics = Samen.Web.Billing.Reads.metrics(billing_mount, scope)

    now = DateTime.utc_now()
    sub_query = Ash.Query.new(Mount.resource(billing_mount, Subscription))
    invoice_query = Ash.Query.new(Mount.resource(billing_mount, Invoice))

    %{
      mrr_cents: metrics.mrr_cents,
      active_subs: metrics.active_subs,
      # TRUE worst-of-N across EVERY subscription this org holds (fix round 1, MED-2)
      # — the honest "worst status in book" DISPLAY text, cancelled included.
      subscription_status: worst_status_via_db(sub_query, scope),
      # T160 P3 — the worst status among the LIVE (non-cancelled) subset, which is what
      # actually DRIVES the billing factor's value (see `billing_factor/1`'s doc).
      scoring_status: live_worst_status_via_db(sub_query, scope),
      # T160 P4 — a book-WIDE DB aggregate, not a 200-row-bounded read.
      past_due: past_due_aggregate(invoice_query, scope, now),
      share: share_counts(sub_query, scope)
    }
  rescue
    e ->
      Logger.warning(
        "Samen.Web.AccountHealth.billing_snapshot/2: read failed, reporting honest absence, never a fabricated $0 (fix round 1 MED-3): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  @doc false
  # T160 — the per-CUSTOMER analogue of `billing_snapshot/2`, filtered to ONE resolved
  # `Billing.Customer`. No `:scoring_status`/`:share` keys — `billing_factor/1` falls
  # back to plain worst-of-N over this customer's OWN subscriptions, correct by
  # construction for a single account (see the moduledoc).
  #
  # NO explicit canary here (unlike `billing_snapshot/2`, which needs one to outrace
  # `Billing.Reads.metrics/2`'s own internal `rescue -> 0`): every read below
  # (`customer_mrr_cents/3`, `worst_status_via_db/2`, `past_due_aggregate/3`) is a
  # DIRECT `Ash.count!`/`Ash.sum!`/`Ash.read_one!` call with NO internal swallowing —
  # this function's OWN `rescue` below is already the first thing that can catch a
  # genuine failure, so the whole read IS the canary. See sabotage 138, which proves
  # this stays true by mutating the rescue itself (the only place a fabricated number
  # could sneak back in), not a since-removed decorative canary line.
  def customer_billing_snapshot(billing_mount, scope, customer_id) do
    sub_query =
      Mount.resource(billing_mount, Subscription)
      |> Ash.Query.new()
      |> Ash.Query.filter(customer_id == ^customer_id)

    invoice_query =
      Mount.resource(billing_mount, Invoice)
      |> Ash.Query.new()
      |> Ash.Query.filter(customer_id == ^customer_id)

    now = DateTime.utc_now()

    %{
      mrr_cents: customer_mrr_cents(billing_mount, scope, customer_id),
      active_subs: Ash.count!(Ash.Query.filter(sub_query, status in [:active, :trialing]), scope: scope),
      subscription_status: worst_status_via_db(sub_query, scope),
      past_due: past_due_aggregate(invoice_query, scope, now)
    }
  rescue
    e ->
      Logger.warning(
        "Samen.Web.AccountHealth.customer_billing_snapshot/3: read failed, reporting honest absence, never a fabricated $0: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      nil
  end

  # MRR for ONE customer = Σ over their OWN active monthly prices (same formula as
  # `Billing.Reads.compute_mrr/2`, scoped to this customer's subscriptions instead of
  # the whole book — zero duplicated FORMULA, just a narrower input set).
  defp customer_mrr_cents(billing_mount, scope, customer_id) do
    subs =
      Mount.resource(billing_mount, Subscription)
      |> Ash.Query.filter(customer_id == ^customer_id and status in [:active, :trialing])
      |> Ash.Query.ensure_selected([:plan_id])
      |> Ash.Query.limit(200)
      |> Ash.read!(scope: scope)

    plan_ids = subs |> Enum.map(& &1.plan_id) |> Enum.uniq()

    if plan_ids == [] do
      0
    else
      prices =
        Mount.resource(billing_mount, Price)
        |> Ash.Query.filter(interval == :monthly and active == true and plan_id in ^plan_ids)
        |> Ash.Query.ensure_selected([:plan_id, :unit_amount])
        |> Ash.Query.limit(200)
        |> Ash.read!(scope: scope)

      Enum.reduce(prices, 0, fn price, acc ->
        count = Enum.count(subs, &(&1.plan_id == price.plan_id))
        acc + count * Samen.Type.Money.cents(price.unit_amount)
      end)
    end
  end

  # T160 P4 — book-wide DB aggregates for the overdue-invoice summary (count/sum are
  # exact `Ash.count!`/`Ash.sum!` aggregates; the oldest-overdue date comes from a
  # `sort + limit(1)` — an ORDER BY/LIMIT the database computes exactly, not a
  # client-side max over a capped row set). Works identically for the portfolio-wide
  # query base and a customer-filtered one.
  defp past_due_aggregate(query_base, scope, now) do
    overdue = Ash.Query.filter(query_base, status in [:open, :draft] and due_date < ^now)

    count = Ash.count!(overdue, scope: scope)
    amount = Ash.sum!(overdue, :amount_due_cents, scope: scope) || 0

    max_days =
      overdue
      |> Ash.Query.sort(due_date: :asc)
      |> Ash.Query.ensure_selected([:due_date])
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)
      |> case do
        nil -> 0
        %{due_date: due} -> div(max(DateTime.diff(now, due), 0), 86_400)
      end

    %{count: count, amount_cents: amount, max_days_overdue: max_days}
  end

  # T160 P4/P5 — the TRUE worst status across EVERY row `query_base` selects, via the
  # `@severity_tiers` cascade (worst-first) then an "anything else is unrecognized"
  # check, then the best case (`:active`/`:trialing`) last. `nil` only when the query
  # matches NO rows at all. Each step is a bounded (`limit(1)`) existence-style read —
  # exact for any book size, never a capped-row-set approximation.
  defp worst_status_via_db(query_base, scope) do
    worst_status_via_db(query_base, scope, @severity_tiers)
  end

  # T160 P3 — the worst status among the LIVE (non-cancelled) subset only: the query is
  # pre-filtered to exclude `:cancelled`/`:canceled` entirely, and the cancelled tier is
  # dropped from the cascade (redundant with the filter, kept out for clarity). `nil`
  # when there are NO live rows (none at all, or every row is cancelled).
  defp live_worst_status_via_db(query_base, scope) do
    live_tiers = Keyword.delete(@severity_tiers, :cancelled)
    live_query = Ash.Query.filter(query_base, status not in [:cancelled, :canceled])
    worst_status_via_db(live_query, scope, live_tiers)
  end

  defp worst_status_via_db(query_base, scope, tiers) do
    known = tiers |> Keyword.values() |> List.flatten()

    Enum.find_value(tiers, fn {_name, statuses} -> first_status_in(query_base, statuses, scope) end) ||
      first_status_not_in(query_base, known ++ [:active, :trialing], scope) ||
      first_status_in(query_base, [:active, :trialing], scope)
  end

  defp first_status_in(query_base, statuses, scope) do
    query_base
    |> Ash.Query.filter(status in ^statuses)
    |> Ash.Query.ensure_selected([:status])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
    |> case do
      nil -> nil
      row -> row.status
    end
  end

  defp first_status_not_in(query_base, statuses, scope) do
    query_base
    |> Ash.Query.filter(status not in ^statuses)
    |> Ash.Query.ensure_selected([:status])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
    |> case do
      nil -> nil
      row -> row.status
    end
  end

  # T160 P3/P4 — DB-aggregate counts by status bucket (exact `Ash.count!`, unbounded).
  # `:cancelled` is surfaced (never hidden) so the composite's copy can disclose churn
  # even though it no longer drives the value down alone (see `billing_factor/1`).
  defp share_counts(query_base, scope) do
    %{
      active: count_matching(query_base, [:active, :trialing], scope),
      cancelled: count_matching(query_base, [:cancelled, :canceled], scope),
      dunning: count_matching(query_base, [:past_due, :unpaid], scope),
      inactive: count_matching(query_base, [:inactive], scope),
      total: Ash.count!(query_base, scope: scope)
    }
  end

  defp count_matching(query_base, statuses, scope) do
    query_base
    |> Ash.Query.filter(status in ^statuses)
    |> Ash.count!(scope: scope)
  end

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
