defmodule Samen.Web.Operator.Reads do
  @moduledoc """
  Operator control-plane read layer (ADR-010 §6). Reads the OPERATOR ORG's own book of
  business on the TENANT plane, so tenant-org accounts and their tenant-admins render PII
  CLEAR — the SaaS owns this data. Assembles "accounts" by joining the Identity/Billing/Support
  scopes over the operator org.

  ## MASKING INVARIANT (inherited from ADR-009)

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, never has a "show
  plaintext" branch. Tenant-admin PII (`User.full_name`/`emails`, `Customer.billing_name`/
  `billing_email`, `Message.body`) is clear ONLY because the operator-org TENANT-plane resolver
  clears own-org PII — the SAME `Samen.Api.PiiResolution.resolve/4` chokepoint the ADR-009 reads
  use. The DOWNSTREAM tenant's end-customer PII is never read here; that is the impersonation
  path (`Samen.Web.CRM.*` under `plane: :operator`), which this module does NOT touch.

  ## Why the account `Org` read is `authorize?: false` but PII stays governed

  The Identity `Org` anchor's read policy is `Samen.Policy.OrgIsSelf` (`id == actor.org_id`) —
  it authorizes only the reader's OWN org row, by design (an org anchor is org-less). The
  operator's per-tenant ACCOUNT rows are OTHER `Org` rows in the operator namespace, so a scoped
  Org read would return only the operator org itself. `Org` carries NO PII (name/slug/plan
  only — ADR-010 §8.3), so it is read here with an explicit `org_id` filter over the operator
  namespace (trusted framework read of its own book of business); the identity line is drawn on
  the PII-bearing joins (Users/Customers/Messages), which DO go through `OrgScope` +
  `PiiResolution` on the tenant plane. Reading a non-PII grouping row leaks nothing.

  ## A3 read-bounding + sanctioned writes

  The hot lists (Accounts, Desk) read through the paginated `accounts_page/3` /
  `desk_page/3` (built on `Samen.Web.Reads.page!/3` — BOUNDED BY CONSTRUCTION); every
  join/lookup read carries an explicit `limit(#{200})`. The write side exposes ONLY
  domain-defined actions: the Org anchor create (account provisioning — always-authorized
  by the identity blueprint's bootstrap policy) and the desk `Ticket` create/destroy
  (member-gated). No account-org destroy is offered — see the write-side section note.
  """

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Operator.HealthScore

  # A3 read-bounding (WS-A design §1.1 "read! elimination"): every join/lookup read on
  # the operator surfaces carries an explicit limit — the kit's hard page cap. These are
  # book-of-business fan-outs (admins per account, agents, price rows), not hot lists;
  # the hot lists themselves read through the paginated `accounts_page/3` / `desk_page/3`.
  @lookup_limit 200

  @doc """
  Assemble the operator's ACCOUNTS (ADR-010 §4a). Each account IS a tenant org
  (`Identity.Org` in the operator namespace), joined to:

    * `:__admins__`   — the account's admin `Identity.User`s (PII CLEAR — the tenant-admins,
      the SaaS's own signup contacts), via `Identity.Membership` where `role == :admin`;
    * `:__subscription__` — the tenant's `Billing.Subscription` (+ Plan + monthly Price →
      `mrr_cents`), the subscription TO the SaaS;
    * `:__seats__`    — the account's membership count (a minimal-viable seat proxy);
    * `:__open_tickets__` — count of the account's open desk `Support.Ticket`s;
    * `:tenant_org_id`   — the impersonation back-reference (`Org.slug`, ADR-010 Bridge-B).

  `operator_org_id` is the operator org whose book this is; account rows are the OTHER Org
  rows in the operator namespace (`org_id == operator_org_id`, `id != operator_org_id`).
  """
  def accounts(mount, scope, operator_org_id) do
    joins = account_joins(mount, scope, operator_org_id)

    account_orgs(mount, operator_org_id)
    |> Enum.map(&account_row(&1, joins))
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of the operator's ACCOUNTS — the A2 `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), the A3 retrofit of
  `accounts/3`. The account `Org` rows are the same trusted non-PII grouping read as
  `account_orgs/2` (`authorize?: false` with an explicit operator-namespace filter —
  see the moduledoc; `OrgIsSelf` would return only the operator org's own row), routed
  through `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION
  (`limit(page_size + 1)`, hostile page sizes clamped, keyset-stable).

  The PII-bearing joins (tenant-admin name/email) resolve exactly as in `accounts/3`:
  `OrgScope` + tenant-plane `PiiResolution` — CLEAR because the SaaS owns population
  (1); this function adds no plaintext path. Sort/filter fields (`name`/`plan`) are
  bounded non-PII attributes. On any read error the page is EMPTY, never unbounded.

  The operator org id resolves from the mount (`Samen.Web.Operator.org_id/1`); with no
  operator org the page is empty.
  """
  def accounts_page(mount, scope, state) do
    case Samen.Web.Operator.org_id(mount) do
      nil ->
        empty_page(state)

      operator_org_id ->
        joins = account_joins(mount, scope, operator_org_id)

        page =
          Mount.resource(mount, Org)
          |> Ash.Query.ensure_selected([:name, :slug, :plan, :org_id])
          |> Ash.Query.filter(org_id == ^operator_org_id and id != ^operator_org_id)
          |> Samen.Web.Reads.page!(state,
            scope: scope,
            authorize?: false,
            filter_fields: [:name]
          )

        %{page | items: Enum.map(page.items, &account_row(&1, joins))}
    end
  rescue
    _ -> empty_page(state)
  end

  # The per-account join maps (admins / subscription / customer / open desk tickets) —
  # each underlying read is OrgScope'd + bounded (`@lookup_limit`). `now` is the ONE
  # clock reading for the whole assembly (B9 carry B4-P2-1): every past-due
  # determination downstream of these joins derives from it, so the evidence flag and
  # the score can never straddle a due-date crossing between two `utc_now` calls.
  defp account_joins(mount, scope, operator_org_id, now \\ DateTime.utc_now()) do
    %{
      admins_by_account: admins_by_account(mount, scope),
      subs_by_customer: subscriptions_by_customer(mount, scope),
      customers_by_account: customers_by_account(mount, scope, operator_org_id),
      tickets_by_account: ticket_counts_by_account(mount, scope),
      past_due_by_account: past_due_by_account(mount, scope, now),
      activity_by_account: activity_by_account(now)
    }
  end

  # The assembled account row + its `%HealthScore.HealthBreakdown{}` (ADR-019). Every
  # score input is a bounded count/enum/cent amount already on the row — the score is
  # a pure fold over this map, never a second read. `__activity_days__` is the G12
  # `pae` recency signal wired into the `:activity` factor (G17b): the whole-days age
  # of this account's most-recent `pae` event (a non-negative integer), or nil (→ the
  # `:unknown` activity factor, AC-G17-7) when the account has no `pae` events yet OR
  # no ProductEvent resource is wired — graceful degradation, never a faked number.
  defp account_row(org, joins) do
    tenant_org_id = org.slug
    admins = Map.get(joins.admins_by_account, tenant_org_id, [])
    customer = Map.get(joins.customers_by_account, tenant_org_id)
    subscription = customer && Map.get(joins.subs_by_customer, customer.id)
    tickets = Map.get(joins.tickets_by_account, tenant_org_id, %{open: 0, breaching: 0})
    past_due = Map.get(joins.past_due_by_account, tenant_org_id, %{count: 0, amount_cents: 0, max_days_overdue: 0})

    row = %{
      id: org.id,
      name: org.name,
      plan: org.plan,
      tenant_org_id: tenant_org_id,
      __admins__: admins,
      __customer__: customer,
      __subscription__: subscription,
      __mrr_cents__: (subscription && subscription.__mrr_cents__) || 0,
      __seats__: length(admins),
      __open_tickets__: tickets.open,
      __breaching_tickets__: tickets.breaching,
      __past_due__: past_due,
      __activity_days__: Map.get(joins.activity_by_account, tenant_org_id)
    }

    Map.put(row, :__health__, HealthScore.score(row))
  end

  defp empty_page(state) do
    %Samen.Web.Page{
      items: [],
      page_size: Samen.Web.Reads.bounded_page_size(state.page_size)
    }
  end

  @doc """
  Platform billing (ADR-010 §4b): per-tenant subscriptions-to-the-SaaS (customer PII CLEAR),
  the invoices the SaaS issues tenants, dunning (past-due), and total platform MRR — computed
  by the SAME monthly-price sum the ADR-009 `Billing.Reads` MRR logic uses, scoped to the
  operator org. Returns `%{subscriptions:, invoices:, dunning:, mrr_cents:, past_due_cents:}`.
  """
  def platform_billing(mount, scope) do
    subs = subscriptions(mount, scope)
    invoices = invoices(mount, scope)
    mrr_cents = Enum.reduce(subs, 0, fn s, acc -> if s.status == :active, do: acc + s.__mrr_cents__, else: acc end)

    now = DateTime.utc_now()

    dunning =
      invoices
      |> Enum.filter(fn inv -> past_due?(inv, now) end)

    past_due_cents = Enum.reduce(dunning, 0, fn inv, acc -> acc + (inv.amount_due_cents || 0) end)

    %{
      subscriptions: subs,
      invoices: invoices,
      dunning: dunning,
      mrr_cents: mrr_cents,
      past_due_cents: past_due_cents,
      active_subs: Enum.count(subs, &(&1.status == :active))
    }
  rescue
    _ -> %{subscriptions: [], invoices: [], dunning: [], mrr_cents: 0, past_due_cents: 0, active_subs: 0}
  end

  @doc """
  The SaaS help desk (ADR-010 §4c): the operator `Support.Ticket` rows tenants filed WITH the
  SaaS, each joined to its requester (a tenant-admin `Identity.User`, PII CLEAR) and its
  handling agent (a SaaS `Support.Agent`, PII CLEAR — both are the SaaS's own). SLA/priority
  ride the Ticket columns. Returns a list of ticket maps.
  """
  def desk(mount, scope) do
    joins = desk_joins(mount, scope)

    Mount.resource(mount, Ticket)
    |> Ash.Query.ensure_selected([:subject, :status, :priority, :sla_breach_at, :breached, :tags, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Enum.map(&desk_row(&1, joins))
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of the SaaS help desk — the A2 `ListLive` reads contract, the
  A3 retrofit of `desk/2`. The `Support.Ticket` read is OrgScope'd on the operator
  org's tenant plane and routed through `Samen.Web.Reads.page!/3` (BOUNDED BY
  CONSTRUCTION). Requester (tenant-admin) / agent joins resolve per plane through
  `PiiResolution` exactly as `desk/2` — CLEAR, the SaaS's own people. Sort/filter
  fields (`subject`/`status`/`priority`) are bounded non-vaulted ticket columns. On
  any read error the page is EMPTY, never unbounded.
  """
  def desk_page(mount, scope, state) do
    joins = desk_joins(mount, scope)

    page =
      Mount.resource(mount, Ticket)
      |> Ash.Query.ensure_selected([:subject, :status, :priority, :sla_breach_at, :breached, :tags, :custom])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:subject])

    %{page | items: Enum.map(page.items, &desk_row(&1, joins))}
  rescue
    _ -> empty_page(state)
  end

  defp desk_joins(mount, scope) do
    %{
      users_by_id: users_by_id(mount, scope),
      agents_by_id: agents_by_id(mount, scope),
      agent_by_ticket: agent_by_ticket(mount, scope)
    }
  end

  defp desk_row(ticket, joins) do
    requester_user_id = get_in(ticket.custom || %{}, ["requester_user_id"])
    requester_org_id = get_in(ticket.custom || %{}, ["requester_org_id"])

    %{
      id: ticket.id,
      subject: ticket.subject,
      status: ticket.status,
      priority: ticket.priority,
      sla_breach_at: ticket.sla_breach_at,
      breached: ticket.breached,
      tags: ticket.tags,
      __requester__: requester_user_id && Map.get(joins.users_by_id, requester_user_id),
      __requester_org_id__: requester_org_id,
      __agent__:
        Map.get(joins.agent_by_ticket, ticket.id)
        |> then(&(&1 && Map.get(joins.agents_by_id, &1)))
    }
  end

  @doc """
  Non-PII desk header metrics as DB aggregates (`Ash.count`) — no row set transferred,
  bounded by construction (A3: this replaced counts computed over the unbounded
  `desk/2` list).
  """
  def desk_metrics(mount, scope) do
    %{
      open: count_tickets(mount, scope, &Ash.Query.filter(&1, status in [:open, :pending])),
      breaching: count_tickets(mount, scope, &Ash.Query.filter(&1, breached == true)),
      high: count_tickets(mount, scope, &Ash.Query.filter(&1, priority in [:urgent, :high]))
    }
  end

  defp count_tickets(mount, scope, filter_fn) do
    Mount.resource(mount, Ticket)
    |> filter_fn.()
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  # -- A3 write side (sanctioned domain actions only) ----------------------------
  #
  # The support blueprint defines `defaults([:read, :destroy, create: :*, update: :*])`
  # member-gated; the identity blueprint's Org create is always-authorized (the anchor
  # bootstrap). This module only exposes those. NO account-org destroy is offered: the
  # Org anchor's destroy is `OrgIsSelf`-gated (an account row is another org's anchor),
  # and the domain defines no operator offboarding action — wiring one would invent
  # policy (WS-A design: only sanctioned actions).

  @doc """
  Destroy one desk ticket for `scope` (A3 CRUD wiring). The write goes through Ash so
  OrgScope + `RoleAtLeast(:member)` apply — this module adds NO policy of its own.
  FAIL-HONEST: a ticket with linked conversations is refused by the DB FK and the
  refusal is returned, never swallowed. `:ok` or `{:error, reason}`.
  """
  def delete_ticket(mount, scope, id) do
    record =
      Mount.resource(mount, Ticket)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      record -> Ash.destroy(record, scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  @doc "Non-PII operator summary metrics for the Accounts page header (bands per ADR-019)."
  def account_metrics(mount, scope, operator_org_id) do
    accounts = accounts(mount, scope, operator_org_id)

    %{
      accounts: length(accounts),
      active: Enum.count(accounts, &(&1.__health__.band == :healthy)),
      at_risk: Enum.count(accounts, &(&1.__health__.band in [:at_risk, :critical])),
      mrr_cents: Enum.reduce(accounts, 0, fn a, acc -> acc + a.__mrr_cents__ end)
    }
  end

  @doc """
  Assemble ONE account's drill-down (WS-B / B4, AC-G17-4): the scored account row
  (`%HealthScore.HealthBreakdown{}` on `__health__`), its `mov` movement timeline,
  its desk tickets, and its invoices — the linked evidence behind each factor.

  Every read is the EXISTING governed path: the account `Org` row is the same trusted
  non-PII grouping read as `account_orgs/2` (explicit operator-namespace filter +
  `limit(1)`); the `mov` timeline is an OrgScope'd, explicitly-bounded Ash read of
  token-blind columns; tickets/invoices reuse the bounded `desk/2` / `invoices/2`
  joins (requester PII resolves through `PiiResolution` per plane — CLEAR on the
  operator's own tenant plane, `••••` on any odd operator-plane mount, AC-G17-5).

  ONE clock reading (B9 carry B4-P2-1): `now` is captured once here and threaded to
  every past-due determination — the score's dunning evidence AND each invoice's
  rendered `__past_due__` flag derive from the SAME instant, so a due date crossing
  "now" mid-assembly can never desync the flag from the score. The LiveView renders
  `__past_due__` verbatim and NEVER reads a clock.

  Returns `%{account:, movements:, tickets:, invoices:}` or `nil` (unknown account /
  read error) — the LiveView renders "not found", never a crash.
  """
  def account_detail(mount, scope, operator_org_id, account_org_id, opts \\ []) do
    case find_account_org(mount, operator_org_id, account_org_id) do
      nil ->
        nil

      org ->
        # ONE clock reading, captured once per assembly (B9 carry B4-P2-1). Defaults to
        # `DateTime.utc_now/0` in production; tests pin it via `:now` (the sanctioned
        # clock-injection opt — same pattern as `Samen.Retention`/`Samen.BreakGlass.Budget`)
        # so the not-yet-due boundary is deterministic instead of a wall-clock margin.
        now = Keyword.get(opts, :now, DateTime.utc_now())
        row = account_row(org, account_joins(mount, scope, operator_org_id, now))
        customer_id = row.__customer__ && row.__customer__.id

        %{
          account: row,
          movements: movements_for_customer(mount, scope, customer_id),
          tickets: desk(mount, scope) |> Enum.filter(&(&1.__requester_org_id__ == row.tenant_org_id)),
          invoices:
            invoices(mount, scope)
            |> Enum.filter(&(&1.customer_id == customer_id))
            |> Enum.map(&Map.put(&1, :__past_due__, past_due?(&1, now)))
        }
    end
  rescue
    _ -> nil
  end

  # The ONE account Org row — the same trusted non-PII grouping read as
  # `account_orgs/2` (see the moduledoc), narrowed to one id, `limit(1)`.
  defp find_account_org(mount, operator_org_id, account_org_id) do
    Mount.resource(mount, Org)
    |> Ash.Query.ensure_selected([:name, :slug, :plan, :org_id])
    |> Ash.Query.filter(org_id == ^operator_org_id and id == ^account_org_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  # The account's `mov` timeline (B1 ledger — token-blind ids/enums/cents/timestamps,
  # AC-G7-3): OrgScope'd, newest first, explicitly bounded.
  defp movements_for_customer(_mount, _scope, nil), do: []

  defp movements_for_customer(mount, scope, customer_id) do
    Mount.resource(mount, SubscriptionEvent)
    |> Ash.Query.ensure_selected([:kind, :mrr_delta_cents, :mrr_before_cents, :mrr_after_cents, :occurred_at, :customer_id])
    |> Ash.Query.filter(customer_id == ^customer_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  # -- private: Identity --------------------------------------------------------

  # The account Org rows (operator namespace). `Org` carries NO PII; read with an explicit
  # org_id filter over the operator namespace (the `OrgIsSelf` policy would return only the
  # operator org's own row, so this trusted non-PII grouping read is authorize?: false — the
  # identity line lives on the PII joins below, all OrgScope + tenant-plane resolved).
  defp account_orgs(mount, operator_org_id) do
    Mount.resource(mount, Org)
    |> Ash.Query.ensure_selected([:name, :slug, :plan, :org_id])
    |> Ash.Query.filter(org_id == ^operator_org_id and id != ^operator_org_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # All tenant-admin Users (admin Membership), PII-resolved on the tenant plane (CLEAR),
  # grouped by their account's tenant_org_id. The account linkage rides the User's non-PII
  # `handle` (seeded to `"acct:<tenant_org_id>"`) — every admin User in the operator namespace
  # carries `org_id == operator_org_id`, so the per-ACCOUNT grouping cannot come from `org_id`;
  # the handle is the account back-reference (non-PII, an existing column, no tnt_field).
  defp admins_by_account(mount, scope) do
    admin_user_ids =
      memberships(mount, scope)
      |> Enum.filter(&(&1.role == :admin))
      |> MapSet.new(& &1.user_id)

    users_by_id(mount, scope)
    |> Map.values()
    |> Enum.filter(&MapSet.member?(admin_user_ids, &1.id))
    |> Enum.reduce(%{}, fn user, acc ->
      case account_key(user.handle) do
        nil -> acc
        tid -> Map.update(acc, tid, [user], &[user | &1])
      end
    end)
  end

  # A tenant-admin User's handle encodes its account: `"acct:<tenant_org_id>"`.
  defp account_key("acct:" <> tid), do: tid
  defp account_key(_), do: nil

  defp memberships(mount, scope) do
    Mount.resource(mount, Membership)
    |> Ash.Query.ensure_selected([:role, :status, :user_id, :org_id])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp users_by_id(mount, scope) do
    Mount.resource(mount, User)
    |> Ash.Query.ensure_selected([:handle, :status, :full_name, :emails])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, User, scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  # -- private: Billing ---------------------------------------------------------

  # Subscriptions with their monthly-price MRR + status. Customer PII resolved (tenant plane).
  defp subscriptions(mount, scope) do
    prices_by_plan = monthly_prices_by_plan(mount, scope)
    plans_by_id = plans_by_id(mount, scope)
    customers = customers(mount, scope)
    customers_by_id = Map.new(customers, &{&1.id, &1})

    Mount.resource(mount, Subscription)
    |> Ash.Query.ensure_selected([:status, :customer_id, :plan_id, :current_period_end])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn sub ->
      mrr = if sub.status == :active, do: Map.get(prices_by_plan, sub.plan_id, 0), else: 0

      %{
        id: sub.id,
        status: sub.status,
        customer_id: sub.customer_id,
        plan_id: sub.plan_id,
        current_period_end: sub.current_period_end,
        __customer__: Map.get(customers_by_id, sub.customer_id),
        __plan__: Map.get(plans_by_id, sub.plan_id),
        __mrr_cents__: mrr
      }
    end)
  rescue
    _ -> []
  end

  defp subscriptions_by_customer(mount, scope) do
    subscriptions(mount, scope) |> Map.new(&{&1.customer_id, &1})
  end

  # Map each account's tenant_org_id -> its Billing.Customer (via customer.custom.tenant_org_id).
  defp customers_by_account(mount, scope, _operator_org_id) do
    customers(mount, scope)
    |> Enum.reduce(%{}, fn cust, acc ->
      case get_in(cust.custom || %{}, ["tenant_org_id"]) do
        nil -> acc
        tid -> Map.put(acc, tid, cust)
      end
    end)
  end

  defp customers(mount, scope) do
    Mount.resource(mount, Customer)
    |> Ash.Query.ensure_selected([:billing_name, :billing_email, :status, :currency, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Customer, scope)
  rescue
    _ -> []
  end

  defp invoices(mount, scope) do
    customers_by_id = customers(mount, scope) |> Map.new(&{&1.id, &1})

    Mount.resource(mount, Invoice)
    |> Ash.Query.ensure_selected([:status, :amount_due_cents, :amount_paid_cents, :currency, :due_date, :paid_at, :customer_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn inv ->
      inv
      |> Map.take([:id, :status, :amount_due_cents, :amount_paid_cents, :currency, :due_date, :paid_at, :customer_id])
      |> Map.put(:__customer__, Map.get(customers_by_id, inv.customer_id))
    end)
  rescue
    _ -> []
  end

  defp plans_by_id(mount, scope) do
    Mount.resource(mount, Plan)
    |> Ash.Query.ensure_selected([:name, :label, :interval])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  # ADR-036 §4.5(3): unit_amount_cents was dropped by the H1 Money migration;
  # unit_amount is now the money_with_currency composite — extract minor units.
  defp monthly_prices_by_plan(mount, scope) do
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount, :interval, :active])
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.plan_id, Samen.Type.Money.cents(&1.unit_amount)})
  rescue
    _ -> %{}
  end

  # -- private: Support ---------------------------------------------------------

  # Per-account desk load: open (status open/pending) + SLA-breaching ticket counts —
  # the support factor's bounded inputs (ADR-019). One pass over the bounded read.
  defp ticket_counts_by_account(mount, scope) do
    Mount.resource(mount, Ticket)
    |> Ash.Query.ensure_selected([:status, :breached, :custom])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Enum.reduce(%{}, fn t, acc ->
      case get_in(t.custom || %{}, ["requester_org_id"]) do
        nil ->
          acc

        tid ->
          acc
          |> bump_count(tid, :open, t.status in [:open, :pending])
          |> bump_count(tid, :breaching, t.breached == true)
      end
    end)
  rescue
    _ -> %{}
  end

  defp bump_count(acc, _tid, _key, false), do: acc

  defp bump_count(acc, tid, key, true) do
    Map.update(acc, tid, %{open: 0, breaching: 0} |> Map.put(key, 1), &Map.update!(&1, key, fn n -> n + 1 end))
  end

  # Per-account DUNNING evidence (the billing factor's inputs — the incoherence fix,
  # AC-G17-2): count / amount / oldest-days-overdue of past-due invoices, grouped by
  # the invoice customer's tenant_org_id back-reference. Reuses the bounded
  # `invoices/2` read; day counts are computed HERE so the score stays clock-free.
  # `now` arrives from the caller (ONE reading per assembly — B9 carry B4-P2-1).
  defp past_due_by_account(mount, scope, now) do
    invoices(mount, scope)
    |> Enum.filter(&past_due?(&1, now))
    |> Enum.reduce(%{}, fn inv, acc ->
      case get_in((inv.__customer__ && inv.__customer__.custom) || %{}, ["tenant_org_id"]) do
        nil ->
          acc

        tid ->
          days = div(max(DateTime.diff(now, inv.due_date), 0), 86_400)

          Map.update(
            acc,
            tid,
            %{count: 1, amount_cents: inv.amount_due_cents || 0, max_days_overdue: days},
            fn pd ->
              %{
                count: pd.count + 1,
                amount_cents: pd.amount_cents + (inv.amount_due_cents || 0),
                max_days_overdue: max(pd.max_days_overdue, days)
              }
            end
          )
      end
    end)
  end

  # -- private: Analytics (pae recency → the health :activity factor, G17b) ------

  # The account's product-activity RECENCY signal — the G17b wire-up that feeds the
  # health score's `:activity` factor (`Samen.Web.Operator.HealthScore.activity_factor/1`:
  # ≤7d → 1.0, ≤30d → 0.7, ≤90d → 0.35, else 0.1; absent → `:unknown`, weights
  # renormalize). For each tenant org, the WHOLE-DAYS age of its most-recent `pae`
  # (`Analytics.ProductEvent`, ADR-021) event vs the threaded `now` — a non-negative
  # integer, mapped by the account's `tenant_org_id` (the `pae` `org_id` IS the tenant
  # org). nil (→ `:unknown`) ONLY when the account has no `pae` events yet OR no
  # ProductEvent resource is wired — graceful, never a faked number.
  #
  # Resolved via the FRAMEWORK config seam (`Samen.Analytics.product_event_resource/0`),
  # NOT `Mount.resource/2`: the Analytics scope materializes in its OWN namespace
  # (`Demo.Analytics.ProductEvent`), decoupled from the operator's Identity mount — the
  # very seam the `track/1` emit + cross-tenant `AnalyticsReads` rollup use to reach
  # `pae` across scopes. Unconfigured (samen_web's own default) → the read is inert
  # (`%{}`), exactly the pre-G17b nil behaviour.
  #
  # BOUNDED BY CONSTRUCTION: one row per org (`DISTINCT ON (org_id)` via Ash
  # `distinct/2` + `distinct_sort/2`, latest `occurred_at` first), hard-capped at
  # `@lookup_limit`. Reads ONLY `[:org_id, :occurred_at]` — a token-blind timestamp, NO
  # PII (`pae` carries no subject identity column by construction; `pae_actor_ref` is
  # never touched). `authorize?: false` reads the operator's OWN book cross-account (the
  # same trusted non-PII grouping posture as `account_orgs/2` and the cross-tenant
  # `AnalyticsReads` rollup); the day count is computed HERE so the score stays
  # clock-free (one `now` per assembly — B9 carry B4-P2-1). Any read failure degrades
  # to `%{}` — it can never empty out the surrounding page.
  defp activity_by_account(now) do
    case Samen.Analytics.product_event_resource() do
      nil -> %{}
      resource -> latest_activity_days(resource, now)
    end
  rescue
    _ -> %{}
  end

  defp latest_activity_days(resource, now) do
    resource
    |> Ash.Query.ensure_selected([:org_id, :occurred_at])
    |> Ash.Query.distinct([:org_id])
    |> Ash.Query.distinct_sort(occurred_at: :desc)
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{}, fn ev, acc ->
      case ev.occurred_at do
        %DateTime{} = at -> Map.put(acc, ev.org_id, activity_days(at, now))
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  end

  # Whole days between an event timestamp and `now` — non-negative (a future-stamped
  # row clamps to 0, never a negative age), the exact shape the score's activity bands
  # expect.
  defp activity_days(occurred_at, now) do
    div(max(DateTime.diff(now, occurred_at), 0), 86_400)
  end

  defp agents_by_id(mount, scope) do
    Mount.resource(mount, Agent)
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Agent, scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  # ticket_id -> agent_id, via the first agent-authored message on the ticket's conversation.
  defp agent_by_ticket(mount, scope) do
    convs_by_ticket =
      Mount.resource(mount, Conversation)
      |> Ash.Query.ensure_selected([:ticket_id])
      |> Ash.Query.limit(@lookup_limit)
      |> Ash.read!(scope: scope)
      |> Map.new(&{&1.id, &1.ticket_id})

    Mount.resource(mount, Message)
    |> Ash.Query.ensure_selected([:conversation_id, :agent_id, :sender_type])
    |> Ash.Query.limit(@lookup_limit)
    |> Ash.read!(scope: scope)
    |> Enum.reduce(%{}, fn msg, acc ->
      ticket_id = Map.get(convs_by_ticket, msg.conversation_id)

      if ticket_id && msg.agent_id && not Map.has_key?(acc, ticket_id) do
        Map.put(acc, ticket_id, msg.agent_id)
      else
        acc
      end
    end)
  rescue
    _ -> %{}
  end

  # -- private: shared ----------------------------------------------------------

  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp past_due?(%{status: status, due_date: %DateTime{} = due}, now)
       when status in [:open, :draft],
       do: DateTime.compare(due, now) == :lt

  defp past_due?(_, _), do: false

  # NOTE (WS-B / B4): the old single-pill `health/1` (subscription status → pill,
  # ADR-010 §4a minimal-viable) is GONE — it ignored past-due invoices (the
  # gate-flagged health/dunning incoherence). `__health__` is now the composite
  # `Samen.Web.Operator.HealthScore` breakdown (ADR-019), whose billing factor is
  # dunning-aware by construction.
end
