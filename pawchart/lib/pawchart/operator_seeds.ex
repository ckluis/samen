defmodule PawChart.OperatorSeeds do
  @moduledoc """
  Stand up the OPERATOR org's book of business (ADR-010) for PawChart — the SaaS company
  (PawChart, Inc.) as a vendor, whose ACCOUNTS ARE the vet CLINICS it serves. This is the
  vet analogue of `Driftwood.OperatorSeeds` (freight brokerages); the operator-plane MECHANISM
  is identical framework substrate, only the account shape (clinics) differs.

  Per account (Bridge-B — the SaaS-owned record of its clinic customer):
    * an operator-side ACCOUNT `Identity.Org` (`slug` = the tenant_org_id back-reference),
    * its clinic-ADMIN `Identity.User` (PII the SaaS OWNS — CLEAR to the operator) + admin
      `Membership`,
    * a `Billing.Plan`/`Price`/`Customer`/`Subscription`/`Invoice` (the clinic's subscription
      TO the SaaS; one invoice PAST-DUE for the at-risk account's dunning surface),
    * a desk `Support.Ticket` the clinic filed WITH the SaaS.

  Idempotent: guarded by an existence check on the operator org.
  """
  require Ash.Query

  alias PawChart.Operator, as: Op

  @operator_org_id "0f000000-0000-4000-8000-0000000000c1"

  @accounts [
    %{tenant_org_id: "c1112d00-0000-4000-8000-000000000001", name: "Happy Paws Clinic", mrr: 29_000, health: :healthy, admin: {"Dana", "Mendez", "dana.mendez@happypaws.example"}},
    %{tenant_org_id: "c1112d00-0000-4000-8000-000000000002", name: "Cedar Vet Hospital", mrr: 49_000, health: :healthy, admin: {"Omar", "Reyes", "omar.reyes@cedarvet.example"}},
    %{tenant_org_id: "c1112d00-0000-4000-8000-000000000003", name: "Riverbend Animal Care", mrr: 79_000, health: :at_risk, admin: {"Priya", "Kaur", "priya.kaur@riverbend.example"}}
  ]

  @agent {"Sam", "Whitfield", "sam.whitfield@pawchart.example"}

  @doc "The well-known operator org id."
  def operator_org_id, do: @operator_org_id

  @doc "Seed the operator book of business (idempotent on the operator org existence)."
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
      %{name: "PawChart, Inc.", plan: "operator", org_id: @operator_org_id, slug: "pawchart"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:id, @operator_org_id)
    |> Ash.create!()
  rescue
    _ ->
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "PawChart, Inc.", plan: "operator"}, authorize?: false)
      |> Ash.create!()
  end

  defp seed_agent do
    {first, last, email} = @agent

    Samen.Factory.create!(
      Op.Agent,
      Map.merge(
        %{org_id: @operator_org_id, handle: "swhitfield", status: :active, role: :agent, email: email},
        Samen.Factory.person(first, last)
      ),
      authorize?: false
    )
  end

  defp define_custom_fields do
    for {table, field} <- [
          {"pqk_ticket", "requester_org_id"},
          {"pqk_ticket", "requester_user_id"},
          {"pmc_customer", "tenant_org_id"}
        ] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: @operator_org_id, table_name: table, field_name: field, type: :string},
          PawChart.Repo
        )
    end

    :ok
  end

  defp seed_account(%{tenant_org_id: tid, name: name, mrr: mrr, admin: {af, al, ae}} = account, agent) do
    health = Map.get(account, :health, :healthy)

    _account_org =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: name, slug: tid, plan: "growth"},
        authorize?: false
      )
      |> Ash.create!()

    admin =
      Samen.Factory.create!(
        Op.User,
        Map.merge(
          %{org_id: @operator_org_id, handle: "acct:#{tid}", status: "active"},
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
    seed_ticket(tid, admin, agent)
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

  defp seed_ticket(tid, admin, agent) do
    sla =
      Op.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @operator_org_id, name: "platform", label: "Platform", priority: :normal, enabled: true},
        actor: %{org_id: @operator_org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    ticket =
      Op.Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @operator_org_id,
          subject: "Cannot export a vaccination report",
          status: :open,
          priority: :high,
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
        %{org_id: @operator_org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: "Re: vaccination report"},
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
        body: "Thanks for reaching out — looking into the vaccination report export now."
      },
      authorize?: false
    )
    |> Ash.create!()
  end
end
