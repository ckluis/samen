defmodule Samen.WebTest.Seeds do
  @moduledoc """
  Seed helpers for `samen_web`'s standalone render tests (ADR-009 §6). Inserts a handful of
  real rows across the mounted CRM/Billing/Support scopes for ONE org — including the
  vault-routed PII fields — so the framework render tests assert against real data on both
  planes (tenant clear / operator ••••).

  The PII values are DISTINCTIVE sentinels (`CONTACT_PLAINTEXT` etc.) so a test can assert
  they appear in the clear on the tenant plane and are ABSENT (masked to ••••) on the
  operator plane.
  """

  # Distinctive PII sentinels — a test asserts these are present (tenant) / absent (operator).
  @contact_first "Aurelia"
  @contact_last "Sentinelson"
  @contact_email "aurelia.plaintext@example.test"
  @contact_phone "+1-555-CLEAR-01"

  @customer_name "Meridian Plaintext Holdings"
  @customer_email "billing.plaintext@example.test"

  @agent_first "Bartholomew"
  @agent_last "Clearname"
  @agent_email "agent.plaintext@example.test"
  @message_body "This message body is PLAINTEXT-SENTINEL-BODY on the tenant plane."

  @doc "Sentinel accessors so tests reference the exact seeded PII strings."
  def contact_full_name, do: "#{@contact_first} #{@contact_last}"
  def contact_email, do: @contact_email
  def contact_phone, do: @contact_phone
  def customer_name, do: @customer_name
  def customer_email, do: @customer_email
  def agent_full_name, do: "#{@agent_first} #{@agent_last}"
  def agent_email, do: @agent_email
  def message_body, do: @message_body

  @doc """
  Seed one org's CRM + Billing + Support data. Returns the `org_id` (a fresh UUID) plus the
  key seeded records for assertions.
  """
  def seed_all do
    org_id = Ash.UUID.generate()

    crm = seed_crm(org_id)
    billing = seed_billing(org_id)
    support = seed_support(org_id)

    %{org_id: org_id, crm: crm, billing: billing, support: support}
  end

  # -- CRM ---------------------------------------------------------------------

  defp seed_crm(org_id) do
    company =
      Samen.WebTest.Crm.Company
      |> Ash.Changeset.for_create(
        :create,
        # No `custom` map — a Tier-1 custom field would need a tnt_field registration; the
        # render tests don't need company_role, so keep the seed to declared attributes.
        %{org_id: org_id, name: "Northwind Freight Co"},
        authorize?: false
      )
      |> Ash.create!()

    person =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          company_id: company.id,
          display_name: "#{@contact_first} #{@contact_last}",
          job_title: "Head of Logistics",
          full_name: %Samen.Type.FullName{first: @contact_first, last: @contact_last},
          emails: [%{label: "work", address: @contact_email}],
          phones: [%{label: "mobile", number: @contact_phone}]
        },
        authorize?: false
      )
      |> Ash.create!()

    stage =
      Samen.WebTest.Crm.Pipeline
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "quoted", label: "Quoted", stage_order: 0, stage_type: "open"},
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    opportunity =
      Samen.WebTest.Crm.Opportunity
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Chicago → Dallas dry van",
          value_cents: 250_000,
          status: :open,
          company_id: company.id,
          pipeline_id: stage.id
        },
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    %{company: company, person: person, stage: stage, opportunity: opportunity}
  end

  # -- Billing -----------------------------------------------------------------

  defp seed_billing(org_id) do
    plan =
      Samen.WebTest.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "growth", label: "Growth", interval: :monthly, enabled: true},
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    _price =
      Samen.WebTest.Billing.Price
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          plan_id: plan.id,
          unit_amount_cents: 29_900,
          currency: "USD",
          interval: :monthly,
          active: true
        },
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    customer =
      Samen.WebTest.Billing.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          billing_name: @customer_name,
          billing_email: @customer_email,
          status: :active,
          currency: "USD"
        },
        authorize?: false
      )
      |> Ash.create!()

    subscription =
      Samen.WebTest.Billing.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: :active,
          current_period_end: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    invoice =
      Samen.WebTest.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          subscription_id: subscription.id,
          status: :open,
          amount_due_cents: 29_900,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second)
        },
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    %{plan: plan, customer: customer, subscription: subscription, invoice: invoice}
  end

  # -- Support -----------------------------------------------------------------

  defp seed_support(org_id) do
    sla =
      Samen.WebTest.Support.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "standard", label: "Standard", priority: :normal, enabled: true},
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    ticket =
      Samen.WebTest.Support.Ticket
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subject: "Missing rate confirmation",
          status: :open,
          priority: :high,
          sla_id: sla.id,
          tags: ["billing"]
        },
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    agent =
      Samen.WebTest.Support.Agent
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          handle: "bclear",
          status: :active,
          role: :agent,
          full_name: %Samen.Type.FullName{first: @agent_first, last: @agent_last},
          email: @agent_email
        },
        authorize?: false
      )
      |> Ash.create!()

    conversation =
      Samen.WebTest.Support.Conversation
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: "Re: rate con"},
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    message =
      Samen.WebTest.Support.Message
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          conversation_id: conversation.id,
          agent_id: agent.id,
          sender_type: :agent,
          message_type: :reply,
          body: @message_body
        },
        authorize?: false
      )
      |> Ash.create!()

    %{sla: sla, ticket: ticket, agent: agent, conversation: conversation, message: message}
  end
end
