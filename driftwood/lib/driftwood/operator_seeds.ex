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

  Idempotent-ish: guarded by an existence check on the operator org.
  """
  require Ash.Query

  alias Driftwood.Operator, as: Op

  # The well-known operator org id (config'd via `:operator_org_id`).
  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  # The tenant orgs Driftwood already seeds (see Driftwood.Seeds.dev_seed/0).
  @accounts [
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000001", name: "Blue Ridge Logistics", mrr: 250_000, admin: {"Marlene", "Okafor", "marlene.okafor@blueridge.example"}},
    %{tenant_org_id: "b1112d00-0000-4000-8000-000000000002", name: "Summit Freight Partners", mrr: 300_000, admin: {"Desmond", "Vlahos", "desmond.vlahos@summitfreight.example"}}
  ]

  @agent {"Priya", "Nakamura", "priya.nakamura@samen.example"}

  @doc "The well-known operator org id."
  def operator_org_id, do: @operator_org_id

  @doc "Seed the operator book of business over the existing tenant orgs. Idempotent-ish."
  def seed do
    if operator_org_seeded?() do
      :ok
    else
      seed_operator_org()
      agent = seed_agent()
      define_custom_fields()

      for account <- @accounts do
        seed_account(account, agent)
      end

      :ok
    end
  end

  defp operator_org_seeded? do
    Op.Org
    |> Ash.Query.filter(id == ^@operator_org_id)
    |> Ash.exists?(authorize?: false)
  rescue
    _ -> false
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
  rescue
    # `force_change_attribute` on a non-writable attribute may be rejected by some Ash
    # versions; fall back to a plain create (a fresh generated id) + config resolution
    # by the single-row fallback in Samen.Web.Operator.org_id/1.
    _ ->
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc.", plan: "operator"}, authorize?: false)
      |> Ash.create!()
  end

  defp seed_agent do
    {first, last, email} = @agent

    Op.Agent
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @operator_org_id,
        handle: "pnakamura",
        status: :active,
        role: :agent,
        full_name: %Samen.Type.FullName{first: first, last: last},
        email: email
      },
      authorize?: false
    )
    |> Ash.create!()
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

  defp seed_account(%{tenant_org_id: tid, name: name, mrr: mrr, admin: {af, al, ae}}, agent) do
    _account_org =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: name, slug: tid, plan: "growth"},
        authorize?: false
      )
      |> Ash.create!()

    admin =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          handle: "acct:#{tid}",
          status: "active",
          full_name: %Samen.Type.FullName{first: af, last: al},
          emails: [%{label: "work", address: ae}]
        },
        authorize?: false
      )
      |> Ash.create!()

    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: @operator_org_id, user_id: admin.id, role: :admin, status: "active"},
      authorize?: false
    )
    |> Ash.create!()

    seed_billing(tid, name, ae, mrr)
    seed_tickets(tid, admin, agent)
  end

  defp seed_billing(tid, name, email, mrr) do
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
      %{org_id: @operator_org_id, plan_id: plan.id, unit_amount_cents: mrr, currency: "USD", interval: :monthly, active: true},
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

    subscription =
      Op.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: :active,
          current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        actor: %{org_id: @operator_org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

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

    # One PAST-DUE invoice for the dunning surface.
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
            tags: ["platform"],
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
