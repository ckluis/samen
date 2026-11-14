defmodule Driftwood.OperatorSeeds do
  @moduledoc """
  Stand up the OPERATOR org's book of business (ADR-010) OVER Driftwood's EXISTING tenant orgs.
  The SaaS company (Samen SaaS, Inc.) is itself an org — the operator org — whose ACCOUNTS ARE
  the freight brokerages Driftwood already seeded (Blue Ridge Logistics + the second brokerage).

  Per account (Bridge-B — a distinct SaaS-owned record of its customer):
    * an operator-side ACCOUNT `Identity.Org` (`slug` = the tenant_org_id back-reference),
    * its tenant-ADMIN `Identity.User` (PII the SaaS OWNS — CLEAR to the operator) + admin
      `Membership`,
    * a `Billing.Customer`/`Subscription`/`Plan`/`Price`/`Invoice` (the tenant's subscription
      TO the SaaS; one invoice PAST-DUE for the dunning surface),
    * 2 desk `Support.Ticket`s the tenant filed WITH the SaaS (requester = the tenant-admin).

  Atomic and convergent: the fresh path (operator org + agent + custom fields + every account + the leads) is ONE
  transaction, and so is each account added on a re-run, so a failure part-way leaves NOTHING behind and the
  existence markers (the operator org row, an account's `Identity.Org` row) cannot outlive the rows they vouch for.
  A re-run seeds only what is missing; an interrupted run from before this change (marker present, agent or
  accounts missing) is still refused loudly rather than reported as success.
  """
  require Ash.Query

  alias Driftwood.Operator, as: Op

  # The well-known operator org id (config'd via `:operator_org_id`).
  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  # ADR-013 §8.3 — the OPERATOR org's ACCOUNTS: one per seeded tenant brokerage (all 5). `health:
  # :at_risk` accounts (#3 Gulf Stream, #5 Ironline) carry a PAST-DUE subscription + invoice for
  # the dunning surface; the rest are healthy (active, no past-due). `mrr` matches the tenant tier.
  @accounts [
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000001", name: "Blue Ridge Logistics", mrr: 250_000, health: :healthy, admin: {"Marlene", "Okafor", "marlene.okafor@blueridge.example"}},
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000002", name: "Summit Freight Partners", mrr: 300_000, health: :healthy, admin: {"Desmond", "Vlahos", "desmond.vlahos@summitfreight.example"}},
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000003", name: "Gulf Stream Carriers", mrr: 480_000, health: :at_risk, admin: {"Yolanda", "Reyes", "yolanda.reyes@gulfstream.example"}},
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000004", name: "Cascade Freightways", mrr: 120_000, health: :healthy, admin: {"Peter", "Lindholm", "peter.lindholm@cascadeway.example"}},
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000005", name: "Ironline Brokerage", mrr: 520_000, health: :at_risk, admin: {"Nadia", "Farouk", "nadia.farouk@ironline.example"}},
    # WS-A A5 (demo coherence) — the JUST-ONBOARDED account: the operator relationship exists
    # (account + admin + subscription), but the TENANT plane is deliberately EMPTY (no freight,
    # CRM, billing, support, marketing, chat, or notification rows), so opening it demonstrates
    # the framework FIRST-RUN checklist + kit empty states + the guarded sample-data offer.
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000006", name: "Lakeline Freight Co", mrr: 120_000, health: :healthy, admin: {"Ingrid", "Bergstrom", "ingrid.bergstrom@lakelinefreight.example"}}
  ]

  # ADR-013 §8.3 — the operator's OWN CRM Leads/prospects (brokerages NOT yet customers), so the
  # operator Leads surface (`/marketing/leads`) is populated. Operator-org-scoped, tenant plane,
  # clear — the SaaS owns these prospect contacts. `lifecycle_stage` is the early funnel.
  @leads [
    {"Coastal Haul Group", "Bianca", "Mercer", "bianca.mercer@coastalhaul.example", "lead"},
    {"Redwood Transit Co", "Warren", "Achebe", "warren.achebe@redwoodtransit.example", "mql"},
    {"Prairie Line Freight", "Sofia", "Kaminski", "sofia.kaminski@prairieline.example", "sql"},
    {"Anchor Point Logistics", "Terrence", "Iyer", "terrence.iyer@anchorpoint.example", "lead"}
  ]

  @leads_company "Prospect brokerages"

  @agent {"Priya", "Nakamura", "priya.nakamura@samen.example"}

  @doc "The well-known operator org id."
  def operator_org_id, do: @operator_org_id

  @doc """
  Seed the operator book of business over the existing tenant orgs. Idempotent AND
  convergent: a fresh DB gets the full book; a re-run on an already-seeded DB seeds
  only the accounts MISSING from `@accounts` (so adding a new account spec — e.g.
  the just-onboarded EMPTY tenant Lakeline Freight Co — lands on the next
  `mix driftwood.seed` without recreating the DB).
  """
  def seed do
    if operator_org_seeded?() do
      seed_missing_accounts()
    else
      atomically(fn ->
        seed_operator_org()
        agent = seed_agent()
        define_custom_fields()

        for account <- @accounts do
          seed_account(account, agent)
        end

        seed_leads()
      end)
    end
  end

  # One transaction for a unit of seeding: a raise anywhere inside rolls the whole unit back and re-raises, so the
  # task exits non-zero and the next run starts that unit from nothing.
  #
  # Ash warns once per create that carries transaction hooks when it runs inside a surrounding transaction. Here the
  # surrounding transaction IS the design (the unit must commit or vanish whole), so the warning is switched off for
  # the span of the unit and restored after.
  defp atomically(fun) do
    previous = Application.fetch_env(:ash, :warn_on_transaction_hooks?)
    Application.put_env(:ash, :warn_on_transaction_hooks?, false)

    try do
      {:ok, :ok} =
        Driftwood.Repo.transaction(fn ->
          fun.()
          :ok
        end)

      :ok
    after
      case previous do
        {:ok, value} -> Application.put_env(:ash, :warn_on_transaction_hooks?, value)
        :error -> Application.delete_env(:ash, :warn_on_transaction_hooks?)
      end
    end
  end

  # Re-run convergence: seed any @accounts entry whose account Org row is absent,
  # reusing the existing desk agent.
  defp seed_missing_accounts do
    agent =
      Op.Agent
      |> Ash.Query.filter(org_id == ^@operator_org_id and handle == "pnakamura")
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    missing = Enum.reject(@accounts, &account_seeded?(&1.tenant_org_id))

    # Accounts to add but no desk agent to attach them to means an earlier seed run stopped half-way. Say so:
    # "nothing to do" would report success for accounts that were never seeded.
    if missing != [] and agent == nil do
      raise "Driftwood.OperatorSeeds: the operator org exists but its desk agent (handle pnakamura) does not, " <>
              "so #{length(missing)} account(s) cannot be seeded — an earlier seed run was interrupted; reset the dev database"
    end

    for account <- missing, do: seed_account(account, agent)

    # The leads ride the same convergence: an operator org seeded before they were atomic with it may lack them.
    unless leads_seeded?(), do: atomically(&seed_leads/0)

    :ok
  end

  defp leads_seeded? do
    Driftwood.Crm.Company
    |> Ash.Query.filter(org_id == ^@operator_org_id and name == ^@leads_company)
    |> Ash.exists?(authorize?: false)
  end

  # The "already there" probes are plain reads and are allowed to RAISE: a probe that answers `true` /
  # `false` on a failed read makes a seed either skip a step it never did (and report success) or repeat
  # one that already ran. A failure surfaces as the task's non-zero exit.
  defp account_seeded?(tenant_org_id) do
    Op.Org
    |> Ash.Query.filter(org_id == ^@operator_org_id and slug == ^tenant_org_id)
    |> Ash.exists?(authorize?: false)
  end

  defp operator_org_seeded? do
    Op.Org
    |> Ash.Query.filter(id == ^@operator_org_id)
    |> Ash.exists?(authorize?: false)
  end

  defp seed_operator_org do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Samen SaaS, Inc.", plan: "operator", org_id: @operator_org_id, slug: "samen"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:id, @operator_org_id)
    |> Ash.create!()
  end

  defp seed_agent do
    {first, last, email} = @agent

    # WS-D D11.1: full_name is the vault-routed composite `Samen.Factory.person/3`
    # builds; `email` is a scalar vaulted attribute (stays inline). Factory.create!
    # owns the vault-aware create + physical-column red-path guard.
    Samen.Factory.create!(
      Op.Agent,
      Map.merge(
        %{
          org_id: @operator_org_id,
          handle: "pnakamura",
          status: :active,
          role: :agent,
          email: email
        },
        Samen.Factory.person(first, last)
      ),
      authorize?: false
    )
  end

  defp define_custom_fields do
    for {table, field} <- [
          {"dqk_ticket", "requester_org_id"},
          {"dqk_ticket", "requester_user_id"},
          {"dpc_customer", "tenant_org_id"}
        ] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: @operator_org_id, table_name: table, field_name: field, type: :string},
          Driftwood.Repo
        )
    end

    :ok
  end

  # One account is ONE transaction: its `Identity.Org` row is the "already seeded" marker `seed_missing_accounts/0`
  # trusts, so it must commit only together with the admin, the billing and the tickets it vouches for.
  @doc false
  def seed_account(account, agent), do: atomically(fn -> do_seed_account(account, agent) end)

  defp do_seed_account(%{tenant_org_id: tid, name: name, mrr: mrr, admin: {af, al, ae}} = account, agent) do
    health = Map.get(account, :health, :healthy)

    _account_org =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: name, slug: tid, plan: "growth"},
        authorize?: false
      )
      |> Ash.create!()

    # WS-D D11.1: vault-routed person PII (full_name + emails) via Samen.Factory.
    admin =
      Samen.Factory.create!(
        Op.User,
        Map.merge(
          %{
            org_id: @operator_org_id,
            handle: "acct:#{tid}",
            status: "active"
          },
          Samen.Factory.person(af, al, email: ae)
        ),
        authorize?: false
      )

    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: @operator_org_id, user_id: admin.id, role: :admin, status: "active"},
      authorize?: false
    )
    |> Ash.create!()

    seed_billing(tid, name, ae, mrr, health)
    seed_tickets(tid, admin, agent)
  end

  defp seed_billing(tid, name, email, mrr, health) do
    plan =
      Op.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: "growth", label: "Growth", interval: :monthly, enabled: true},
        actor: %{org_id: @operator_org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    Op.Price
    |> Ash.Changeset.for_create(
      :create,
      # ADR-036 §4.5(5): unit_amount_cents/currency dropped by the H1 Money migration.
      %{org_id: @operator_org_id, plan_id: plan.id, unit_amount: Samen.Type.Money.from_cents(mrr, :USD), interval: :monthly, active: true},
      actor: %{org_id: @operator_org_id, role: :admin},
      authorize?: false
    )
    |> Ash.create!()

    customer =
      Op.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          billing_name: name,
          billing_email: email,
          status: :active,
          currency: "USD",
          custom: %{"tenant_org_id" => tid}
        },
        authorize?: false
      )
      |> Ash.create!()

    # An at-risk account's subscription is PAST-DUE (drives the accounts "at risk" health pill,
    # ADR-010 §4a); a healthy account is active. Only at-risk accounts carry a past-due invoice.
    sub_status = if health == :at_risk, do: :past_due, else: :active

    subscription =
      Op.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: sub_status,
          current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        actor: %{org_id: @operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    # A current, open invoice (due in the future).
    Op.Invoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @operator_org_id,
        customer_id: customer.id,
        subscription_id: subscription.id,
        status: :open,
        amount_due_cents: mrr,
        currency: "USD",
        due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second)
      },
      actor: %{org_id: @operator_org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()

    # One PAST-DUE invoice for the dunning surface — ONLY for at-risk accounts.
    if health == :at_risk do
      Op.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          customer_id: customer.id,
          subscription_id: subscription.id,
          status: :open,
          amount_due_cents: mrr,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
        },
        actor: %{org_id: @operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  # ADR-013 §8.3 — the operator's OWN CRM Leads/prospects (brokerages NOT yet customers). Seeded
  # as `Driftwood.Crm.Person` rows under the OPERATOR org id (tenant plane, clear — the SaaS owns
  # these prospect contacts), with an early-funnel `lifecycle_stage`, so the operator Leads lens
  # (`/marketing/leads?org=<operator_org_id>`, the framework LeadsLive) is populated. Idempotent
  # via the `@leads_company` existence guard (`seed_missing_accounts/0`) and atomic with the fresh path.
  defp seed_leads do
    # The Tier-1 custom fields these operator-org CRM rows write (a custom-bag value is rejected
    # unless a `tnt_field` definition exists for THIS org). `company_role` rides the Company bag;
    # `lifecycle_stage` rides the Person bag. Both non-PII; idempotent (on_conflict: :replace).
    for {table, field} <- [{"fcm_company", "company_role"}, {"fpr_person", "lifecycle_stage"}] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: @operator_org_id, table_name: table, field_name: field, type: :string},
          Driftwood.Repo
        )
    end

    # A prospects company grouping row (non-PII) so the leads attach to a Company.
    company =
      Driftwood.Crm.Company
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: @leads_company, custom: %{"company_role" => "prospect"}},
        authorize?: false
      )
      |> Ash.create!()

    for {_prospect_co, first, last, email, stage} <- @leads do
      # WS-D D11.1: vault-routed person PII (full_name + emails) via Samen.Factory;
      # the non-PII `custom` bag + scalars stay in the merged attrs map.
      Samen.Factory.create!(
        Driftwood.Crm.Person,
        Map.merge(
          %{
            org_id: @operator_org_id,
            company_id: company.id,
            display_name: "#{first} #{last}",
            job_title: "VP Operations",
            custom: %{"lifecycle_stage" => stage}
          },
          Samen.Factory.person(first, last, email: email)
        ),
        authorize?: false
      )
    end

    :ok
  end

  defp seed_tickets(tid, admin, agent) do
    sla =
      Op.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: "platform", label: "Platform", priority: :normal, enabled: true},
        actor: %{org_id: @operator_org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    for {subject, priority} <- [
          {"Cannot invite a second admin", :high},
          {"Invoice PDF export failing", :normal}
        ] do
      ticket =
        Op.Ticket
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: @operator_org_id,
            subject: subject,
            status: :open,
            priority: priority,
            sla_id: sla.id,
            custom: %{"requester_org_id" => tid, "requester_user_id" => admin.id}
          },
          actor: %{org_id: @operator_org_id, role: :member},
          authorize?: false
        )
        |> Ash.create!()

      conversation =
        Op.Conversation
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: @operator_org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: "Re: #{subject}"},
          actor: %{org_id: @operator_org_id, role: :member},
          authorize?: false
        )
        |> Ash.create!()

      Op.Message
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          conversation_id: conversation.id,
          agent_id: agent.id,
          sender_type: :agent,
          message_type: :reply,
          body: "Thanks for reaching out — looking into #{subject} now."
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end
end
