defmodule Samen.WebTest.Operator.Seeds do
  @moduledoc """
  Seed helper for the operator / SaaS-company control plane (ADR-010 §8.2, §8.3). Stands up the
  operator org's book of business OVER a set of tenant orgs:

    * ONE operator Org (the SaaS company itself) — the well-known operator org id.
    * The SaaS's OWN support staff (`Support.Agent`s, PII CLEAR — the SaaS's employees).
    * Per tenant (the bridge — ADR-010 Bridge-B): an operator-side ACCOUNT `Identity.Org`
      (`slug` = the tenant_org_id back-reference), its tenant-ADMIN `Identity.User` (a
      distinctive CLEAR sentinel name/email — the PII the SaaS OWNS) + admin `Membership`, a
      `Billing.Customer`/`Subscription`/`Plan`/`Price`/`Invoice` (the tenant's subscription TO
      the SaaS; one invoice PAST-DUE), and 2 desk `Support.Ticket`s the tenant filed WITH the
      SaaS (requester = the tenant-admin, carried in the ticket `custom` bag).

  Plus — for the identity-line test — one DOWNSTREAM tenant END-customer `Person` in the
  EXISTING `Samen.WebTest.Crm` namespace (a distinctive MASKED sentinel), so the test can assert
  clear (operator plane) vs masked (impersonation plane) on two different populations.

  ## The two PII sentinels (the identity line)

    * `admin_full_name/0` + `admin_email/0` — population (1): the tenant-ADMIN, the SaaS's OWN
      customer. Asserted PRESENT (clear) on the operator plane.
    * `Samen.WebTest.Seeds.contact_full_name/0` — population (2): the tenant's downstream
      end-customer. Asserted ABSENT (`••••`) to the operator on the impersonation plane.
  """

  alias Samen.WebTest.Operator, as: Op

  # Population (1) sentinel — the tenant-ADMIN, the SaaS's OWN signup contact (CLEAR to operator).
  @admin_first "Reginald"
  @admin_last "Adminclear"
  @admin_email "reginald.admin.clear@saas.test"

  @agent_first "Priya"
  @agent_last "Staffclear"
  @agent_email "priya.staff.clear@saas.test"

  @doc "Sentinel accessors for the identity-line test (population 1 — CLEAR)."
  def admin_full_name, do: "#{@admin_first} #{@admin_last}"
  def admin_email, do: @admin_email
  def agent_full_name, do: "#{@agent_first} #{@agent_last}"

  @doc """
  Seed the whole operator book of business. Returns a map with `:operator_org_id`, the seeded
  `:accounts` (each with its `:tenant_org_id`, `:admin`, `:subscription`, `:tickets`), and the
  downstream `:tenant_end_customer` (a `Samen.WebTest.Crm` Person, masked to the operator).
  """
  def seed_all(opts \\ []) do
    tenant_count = Keyword.get(opts, :tenants, 2)

    operator_org = seed_operator_org()
    operator_org_id = operator_org.id
    agent = seed_agent(operator_org_id)
    define_custom_fields(operator_org_id)

    # The downstream tenant world: a real tenant org in the vertical namespace, with an
    # end-customer Person whose PII must be MASKED to the operator (population 2).
    %{org_id: tenant_org_id, crm: %{person: end_customer}} = Samen.WebTest.Seeds.seed_all()

    accounts =
      for i <- 1..tenant_count do
        # The FIRST account maps to the real seeded tenant org (so the impersonation drill has a
        # real downstream world); the rest are additional book-of-business accounts.
        acct_tenant_org_id = if i == 1, do: tenant_org_id, else: Ash.UUID.generate()
        seed_account(operator_org_id, acct_tenant_org_id, i, agent)
      end

    %{
      operator_org_id: operator_org_id,
      agent: agent,
      accounts: accounts,
      tenant_org_id: tenant_org_id,
      tenant_end_customer: end_customer
    }
  end

  # -- operator org + agent ----------------------------------------------------

  # Create the operator org (id auto-generated), then align its own `org_id` to its `id`
  # (the anchor is self-scoped). Its id becomes the well-known operator org id everywhere.
  defp seed_operator_org do
    org =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Samen SaaS, Inc.", plan: "operator"},
        authorize?: false
      )
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{org_id: org.id}, authorize?: false)
    |> Ash.update!()
  end

  defp seed_agent(operator_org_id) do
    Op.Agent
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: operator_org_id,
        handle: "pstaff",
        status: :active,
        role: :agent,
        full_name: %Samen.Type.FullName{first: @agent_first, last: @agent_last},
        email: @agent_email
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # The Tier-1 custom fields the operator rows write (T3.8: a custom-bag value is rejected
  # unless a `tnt_field` definition exists). `requester_org_id`/`requester_user_id` ride the
  # ticket bag; `tenant_org_id` rides the customer bag. All non-PII UUID strings.
  defp define_custom_fields(operator_org_id) do
    for {table, field} <- [
          {"wqk_ticket", "requester_org_id"},
          {"wqk_ticket", "requester_user_id"},
          {"wpc_customer", "tenant_org_id"}
        ] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: operator_org_id, table_name: table, field_name: field, type: :string},
          Samen.WebTest.Repo
        )
    end

    :ok
  end

  # -- one account (a tenant org, mirrored into the operator namespace) ---------

  defp seed_account(operator_org_id, tenant_org_id, i, agent) do
    account_org = seed_account_org(operator_org_id, tenant_org_id, i)
    admin = seed_admin_user(operator_org_id, tenant_org_id, i)
    _membership = seed_admin_membership(operator_org_id, admin)

    billing = seed_billing(operator_org_id, tenant_org_id, i)
    tickets = seed_tickets(operator_org_id, tenant_org_id, admin, agent, i)

    %{
      account_org: account_org,
      tenant_org_id: tenant_org_id,
      admin: admin,
      subscription: billing.subscription,
      customer: billing.customer,
      invoice: billing.invoice,
      past_due_invoice: billing.past_due_invoice,
      tickets: tickets
    }
  end

  # The account Org — its `slug` carries the tenant_org_id back-reference (Bridge-B join key).
  defp seed_account_org(operator_org_id, tenant_org_id, i) do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: operator_org_id,
        name: "Blue Ridge Logistics #{i}",
        slug: tenant_org_id,
        plan: "growth"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # The tenant-ADMIN User — PII CLEAR (the SaaS's OWN signup contact). Its non-PII `handle`
  # encodes the account back-reference (`"acct:<tenant_org_id>"`) so the reads group admins by
  # account without an ambiguous org_id join (every admin carries org_id == operator_org_id).
  defp seed_admin_user(operator_org_id, tenant_org_id, i) do
    Op.User
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: operator_org_id,
        handle: "acct:#{tenant_org_id}",
        status: "active",
        full_name: %Samen.Type.FullName{first: @admin_first, last: "#{@admin_last}#{suffix(i)}"},
        emails: [%{label: "work", address: admin_email_for(i)}]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_admin_membership(operator_org_id, admin) do
    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: operator_org_id, user_id: admin.id, role: :admin, status: "active"},
      authorize?: false
    )
    |> Ash.create!()
  end

  # -- billing (the tenant's subscription TO the SaaS) -------------------------

  defp seed_billing(operator_org_id, tenant_org_id, i) do
    plan =
      Op.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: operator_org_id, name: "growth", label: "Growth", interval: :monthly, enabled: true},
        actor: %{org_id: operator_org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    _price =
      Op.Price
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          plan_id: plan.id,
          # ADR-036 §4.5(5): unit_amount_cents/currency dropped by the H1 Money migration.
          unit_amount: Samen.Type.Money.from_cents(49_900, :USD),
          interval: :monthly,
          active: true
        },
        actor: %{org_id: operator_org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    # Every OTHER account is past-due (so the dunning surface + at-risk health are non-vacuous).
    sub_status = if rem(i, 2) == 0, do: :past_due, else: :active

    customer =
      Op.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          billing_name: "#{@admin_first} #{@admin_last}#{suffix(i)}",
          billing_email: admin_email_for(i),
          status: :active,
          currency: "USD",
          custom: %{"tenant_org_id" => tenant_org_id}
        },
        authorize?: false
      )
      |> Ash.create!()

    subscription =
      Op.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: sub_status,
          current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        actor: %{org_id: operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    # A current, open invoice (due in the future).
    invoice =
      Op.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          customer_id: customer.id,
          subscription_id: subscription.id,
          status: :open,
          amount_due_cents: 49_900,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second)
        },
        actor: %{org_id: operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    # One PAST-DUE invoice (due in the past, still open → dunning).
    past_due_invoice =
      Op.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: operator_org_id,
          customer_id: customer.id,
          subscription_id: subscription.id,
          status: :open,
          amount_due_cents: 49_900,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
        },
        actor: %{org_id: operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    %{plan: plan, customer: customer, subscription: subscription, invoice: invoice, past_due_invoice: past_due_invoice}
  end

  # -- desk tickets (tenant → SaaS) --------------------------------------------

  defp seed_tickets(operator_org_id, tenant_org_id, admin, agent, _i) do
    sla =
      Op.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: operator_org_id, name: "platform", label: "Platform", priority: :normal, enabled: true},
        actor: %{org_id: operator_org_id, role: :admin},
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
            org_id: operator_org_id,
            subject: subject,
            status: :open,
            priority: priority,
            sla_id: sla.id,
            custom: %{
              "requester_org_id" => tenant_org_id,
              "requester_user_id" => admin.id
            }
          },
          actor: %{org_id: operator_org_id, role: :member},
          authorize?: false
        )
        |> Ash.create!()

      conversation =
        Op.Conversation
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: operator_org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: "Re: #{subject}"},
          actor: %{org_id: operator_org_id, role: :member},
          authorize?: false
        )
        |> Ash.create!()

      _message =
        Op.Message
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: operator_org_id,
            conversation_id: conversation.id,
            agent_id: agent.id,
            sender_type: :agent,
            message_type: :reply,
            body: "Thanks for reaching out — looking into #{subject} now."
          },
          authorize?: false
        )
        |> Ash.create!()

      ticket
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp suffix(1), do: ""
  defp suffix(i), do: " #{i}"

  defp admin_email_for(1), do: @admin_email

  defp admin_email_for(i) do
    [name, domain] = String.split(@admin_email, "@", parts: 2)
    "#{name}+#{i}@#{domain}"
  end
end
