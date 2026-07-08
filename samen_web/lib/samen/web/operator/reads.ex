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
  """

  require Ash.Query

  alias Samen.Web.Mount

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
    admins_by_account = admins_by_account(mount, scope)
    subs_by_customer = subscriptions_by_customer(mount, scope)
    customers_by_account = customers_by_account(mount, scope, operator_org_id)
    tickets_by_account = open_ticket_counts(mount, scope)

    account_orgs(mount, operator_org_id)
    |> Enum.map(fn org ->
      tenant_org_id = org.slug
      admins = Map.get(admins_by_account, tenant_org_id, [])
      customer = Map.get(customers_by_account, tenant_org_id)
      subscription = customer && Map.get(subs_by_customer, customer.id)

      %{
        id: org.id,
        name: org.name,
        plan: org.plan,
        tenant_org_id: tenant_org_id,
        __admins__: admins,
        __customer__: customer,
        __subscription__: subscription,
        __mrr_cents__: (subscription && subscription.__mrr_cents__) || 0,
        __seats__: length(admins),
        __open_tickets__: Map.get(tickets_by_account, tenant_org_id, 0),
        __health__: health(subscription)
      }
    end)
  rescue
    _ -> []
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
    users_by_id = users_by_id(mount, scope)
    agents_by_id = agents_by_id(mount, scope)
    agent_by_ticket = agent_by_ticket(mount, scope)

    Mount.resource(mount, Ticket)
    |> Ash.Query.ensure_selected([:subject, :status, :priority, :sla_breach_at, :breached, :tags, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn ticket ->
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
        __requester__: requester_user_id && Map.get(users_by_id, requester_user_id),
        __requester_org_id__: requester_org_id,
        __agent__: Map.get(agent_by_ticket, ticket.id) |> then(&(&1 && Map.get(agents_by_id, &1)))
      }
    end)
  rescue
    _ -> []
  end

  @doc "Non-PII operator summary metrics for the Accounts page header."
  def account_metrics(mount, scope, operator_org_id) do
    accounts = accounts(mount, scope, operator_org_id)

    %{
      accounts: length(accounts),
      active: Enum.count(accounts, &(&1.__health__ == :healthy)),
      at_risk: Enum.count(accounts, &(&1.__health__ == :at_risk)),
      mrr_cents: Enum.reduce(accounts, 0, fn a, acc -> acc + a.__mrr_cents__ end)
    }
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
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp users_by_id(mount, scope) do
    Mount.resource(mount, User)
    |> Ash.Query.ensure_selected([:handle, :status, :full_name, :emails])
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
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  defp monthly_prices_by_plan(mount, scope) do
    Mount.resource(mount, Price)
    |> Ash.Query.ensure_selected([:plan_id, :unit_amount_cents, :interval, :active])
    |> Ash.Query.filter(interval == :monthly and active == true)
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.plan_id, &1.unit_amount_cents})
  rescue
    _ -> %{}
  end

  # -- private: Support ---------------------------------------------------------

  defp open_ticket_counts(mount, scope) do
    Mount.resource(mount, Ticket)
    |> Ash.Query.ensure_selected([:status, :custom])
    |> Ash.read!(scope: scope)
    |> Enum.reduce(%{}, fn t, acc ->
      case get_in(t.custom || %{}, ["requester_org_id"]) do
        nil ->
          acc

        tid ->
          if t.status in [:open, :pending], do: Map.update(acc, tid, 1, &(&1 + 1)), else: acc
      end
    end)
  rescue
    _ -> %{}
  end

  defp agents_by_id(mount, scope) do
    Mount.resource(mount, Agent)
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email])
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
      |> Ash.read!(scope: scope)
      |> Map.new(&{&1.id, &1.ticket_id})

    Mount.resource(mount, Message)
    |> Ash.Query.ensure_selected([:conversation_id, :agent_id, :sender_type])
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

  # Health pill from subscription status (ADR-010 §4a minimal-viable).
  defp health(nil), do: :unknown
  defp health(%{status: :active}), do: :healthy
  defp health(%{status: :past_due}), do: :at_risk
  defp health(%{status: :cancelled}), do: :churned
  defp health(%{status: :canceled}), do: :churned
  defp health(_), do: :unknown
end
