defmodule PawChart.Seeds do
  @moduledoc """
  Seeds for PawChart — minimal clinic-flavored data for the inherited CRM/Billing/Support
  scopes so the samen_web UI pages render REAL rows.

  The THREE INHERITED SCOPES all get seeded here:

    * CRM — referring vets, labs, vendors (clinic contacts), pipeline stages, a deal.
    * Billing — a clinic subscription on a "vet_pro" plan, a paid invoice.
    * Support — a clinic ticket filed with the platform + an agent.

  The POINT of this seed is the dogfood demonstration: after `mix pawchart.seed`, visiting
  `/crm/contacts?org=<uuid>`, `/billing?org=<uuid>`, and `/support?org=<uuid>` all render
  real data sourced from PawChart's mounted scopes — ZERO PawChart LiveView code.

  The clinic org has a FIXED uuid so the dev one-liner and the LiveView `?org=<uuid>`
  param agree without ceremony.
  """

  require Ash.Query

  # Fixed clinic org id — same convention as Driftwood's `@blue_ridge_org_id`.
  @clinic_org_id "c1112d00-0000-4000-8000-000000000001"

  @doc "The fixed Happy Paws Clinic tenant org id."
  def clinic_org_id, do: @clinic_org_id

  # CRM companies: a mix of clinic contacts (referring vets, labs, vendors).
  @companies [
    %{name: "Valley Animal Hospital", industry: "veterinary"},
    %{name: "Westside Veterinary Group", industry: "veterinary"},
    %{name: "PetLab Diagnostics", industry: "diagnostics"},
    %{name: "MedVet Specialists", industry: "veterinary"},
    %{name: "PawsPlus Supply Co", industry: "supplies"}
  ]

  # CRM people: clinic contacts (receptionists, referring vet reps, billing contacts).
  # Each has full_name/emails/phones → vault-routed PII; masked on the operator plane.
  @people [
    {"Valley Animal Hospital", "Dr. Maya", "Singh", "referring vet", "maya.singh@valleyanimal.example", "+1-415-555-0101"},
    {"Valley Animal Hospital", "Lena", "Park", "billing contact", "lena.park@valleyanimal.example", "+1-415-555-0109"},
    {"Westside Veterinary Group", "Dr. Carlos", "Mendez", "referring vet", "carlos.mendez@westsidevetgroup.example", "+1-510-555-0115"},
    {"PetLab Diagnostics", "Jordan", "Ellis", "lab coordinator", "jordan.ellis@petlabdx.example", "+1-650-555-0122"},
    {"MedVet Specialists", "Dr. Priya", "Agarwal", "specialist", "priya.agarwal@medvet.example", "+1-408-555-0130"},
    {"PawsPlus Supply Co", "Riley", "Chen", "account rep", "riley.chen@pawsplus.example", "+1-925-555-0118"}
  ]

  # CRM pipeline stages: vet clinic onboarding flow.
  @pipeline_stages [
    %{name: "prospect", label: "Prospect", stage_order: 0, stage_type: "open"},
    %{name: "contacted", label: "Contacted", stage_order: 1, stage_type: "qualified"},
    %{name: "demo", label: "Demo Scheduled", stage_order: 2, stage_type: "proposal"},
    %{name: "trial", label: "Trial", stage_order: 3, stage_type: "proposal"},
    %{name: "won", label: "Won", stage_order: 4, stage_type: "won"}
  ]

  # Support agents: platform support staff (PII: full_name + email).
  @agents [
    {"vet-support-1", "Simone", "Hartley", "simone.hartley@pawchart.example", :agent},
    {"vet-support-2", "Daisuke", "Mori", "daisuke.mori@pawchart.example", :supervisor}
  ]

  # Support tickets: clinics file tickets with the platform.
  @tickets [
    {"Unable to add new patient record", :open, :high},
    {"Billing invoice amount incorrect for March", :pending, :normal},
    {"How do I export vaccination reports?", :resolved, :low},
    {"Integration with Cornerstone PIMS failing", :open, :urgent}
  ]

  @doc """
  Seed ALL three inherited scopes (CRM / Billing / Support) for `org_id` (default:
  the Happy Paws Clinic fixed org). Idempotent (guarded by a CRM company existence check).
  Returns the org id.
  """
  def run(org_id \\ @clinic_org_id) do
    if seeded?(org_id) do
      IO.puts("PawChart seeds already present for org #{org_id} — skipping.")
      org_id
    else
      IO.puts("Seeding PawChart for org #{org_id}…")
      seed_crm(org_id)
      seed_billing(org_id)
      seed_support(org_id)
      IO.puts("PawChart seed complete. Visit /crm/contacts?org=#{org_id}")
      org_id
    end
  end

  # -- Idempotency guard -------------------------------------------------------

  defp seeded?(org_id) do
    actor = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}

    PawChart.Crm.Company
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.exists?(actor: actor, authorize?: false)
  end

  # -- CRM builders ------------------------------------------------------------

  defp seed_crm(org_id) do
    companies = seed_crm_companies(org_id)
    stages = seed_pipeline_stages(org_id)
    seed_crm_people(org_id, companies)
    seed_crm_opportunity(org_id, companies, stages)
  end

  defp seed_crm_companies(org_id) do
    for %{name: name, industry: industry} <- @companies, into: %{} do
      company =
        PawChart.Crm.Company
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, name: name, industry: industry},
          authorize?: false
        )
        |> Ash.create!()

      {name, company}
    end
  end

  defp seed_pipeline_stages(org_id) do
    for stage <- @pipeline_stages, into: %{} do
      s =
        PawChart.Crm.Pipeline
        |> Ash.Changeset.for_create(
          :create,
          Map.put(stage, :org_id, org_id),
          actor: %{org_id: org_id, role: :admin},
          authorize?: false
        )
        |> Ash.create!()

      {stage.name, s}
    end
  end

  defp seed_crm_people(org_id, companies) do
    for {company_name, first, last, title, email, phone} <- @people do
      company = Map.fetch!(companies, company_name)

      PawChart.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          company_id: company.id,
          display_name: "#{first} #{last}",
          job_title: title,
          full_name: %Samen.Type.FullName{first: first, last: last},
          emails: [%{label: "work", address: email}],
          phones: [%{label: "direct", number: phone}]
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp seed_crm_opportunity(org_id, companies, stages) do
    company = companies |> Map.values() |> List.first()
    stage = Map.get(stages, "demo")

    PawChart.Crm.Opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: "Valley Animal Hospital — Pro Plan Upsell",
        value_cents: 119_800,
        status: :open,
        company_id: company.id,
        pipeline_id: stage && stage.id
      },
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  # -- Billing builders --------------------------------------------------------

  defp seed_billing(org_id) do
    actor = %{org_id: org_id, role: :admin}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    plan =
      PawChart.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "vet_pro",
          label: "VetPro",
          interval: :monthly,
          enabled: true
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    _price =
      PawChart.Billing.Price
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          plan_id: plan.id,
          unit_amount_cents: 9_900,
          currency: "USD",
          interval: :monthly,
          active: true
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    customer =
      PawChart.Billing.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          billing_name: "Happy Paws Veterinary Clinic LLC",
          billing_email: "billing@happypaws.example",
          status: :active,
          currency: "USD"
        },
        authorize?: false
      )
      |> Ash.create!()

    sub =
      PawChart.Billing.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          plan_id: plan.id,
          status: :active,
          current_period_start: DateTime.add(now, -15 * 86_400, :second),
          current_period_end: DateTime.add(now, 15 * 86_400, :second)
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    # Paid invoice
    invoice =
      PawChart.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          subscription_id: sub.id,
          status: :paid,
          amount_due_cents: 9_900,
          amount_paid_cents: 9_900,
          currency: "USD",
          period_start: DateTime.add(now, -30 * 86_400, :second),
          period_end: now,
          due_date: DateTime.add(now, -10 * 86_400, :second),
          paid_at: DateTime.add(now, -12 * 86_400, :second),
          line_items: [
            %{"description" => "VetPro — monthly subscription", "amount_cents" => 9_900, "quantity" => 1}
          ]
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    PawChart.Billing.Payment
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        invoice_id: invoice.id,
        customer_id: customer.id,
        status: :succeeded,
        amount_cents: 9_900,
        currency: "USD",
        payment_method_type: :card,
        last4: "4242",
        paid_at: DateTime.add(now, -12 * 86_400, :second)
      },
      actor: actor,
      authorize?: false
    )
    |> Ash.create!()

    :ok
  end

  # -- Support builders --------------------------------------------------------

  defp seed_support(org_id) do
    actor = %{org_id: org_id, role: :admin}
    member = %{org_id: org_id, role: :member}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # SLA policy (Tier-0 config).
    sla =
      PawChart.Support.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "standard",
          label: "Standard clinic support SLA",
          first_response_minutes: 120,
          resolve_minutes: 720,
          priority: :normal,
          enabled: true
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    # Agents WITH PII (full_name composite + email scalar, both vaulted).
    agents =
      for {handle, first, last, email, role} <- @agents do
        PawChart.Support.Agent
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            handle: handle,
            full_name: %Samen.Type.FullName{first: first, last: last},
            email: email,
            role: role,
            status: :active,
            timezone: "America/Los_Angeles"
          },
          authorize?: false
        )
        |> Ash.create!()
      end

    [primary_agent | _] = agents

    @tickets
    |> Enum.with_index()
    |> Enum.each(fn {{subject, status, priority}, idx} ->
      agent = Enum.at(agents, rem(idx, length(agents)))

      resolved_at =
        if status in [:resolved, :closed], do: DateTime.add(now, -2 * 86_400, :second), else: nil

      ticket =
        PawChart.Support.Ticket
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            subject: subject,
            status: status,
            priority: priority,
            sla_id: sla.id,
            sla_breach_at: DateTime.add(now, sla.resolve_minutes * 60, :second),
            resolved_at: resolved_at,
            tags: ["clinic-support"]
          },
          actor: member,
          authorize?: false
        )
        |> Ash.create!()

      # Conversation + messages on the first two tickets.
      if idx < 2 do
        conversation =
          PawChart.Support.Conversation
          |> Ash.Changeset.for_create(
            :create,
            %{
              org_id: org_id,
              ticket_id: ticket.id,
              channel: :email,
              status: :open,
              subject: subject
            },
            actor: member,
            authorize?: false
          )
          |> Ash.create!()

        PawChart.Support.Message
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            conversation_id: conversation.id,
            sender_type: :customer,
            message_type: :reply,
            created_via: :email,
            body: "Hi — we are experiencing the issue described in \"#{subject}\". Our clinic uses PawChart daily and this is blocking operations. Please help."
          },
          authorize?: false
        )
        |> Ash.create!()

        PawChart.Support.Message
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            conversation_id: conversation.id,
            agent_id: agent.id,
            sender_type: :agent,
            sender_id: agent.id,
            message_type: :reply,
            created_via: :web,
            body: "Thank you for reaching out. We have created a case and our team is investigating. We will follow up within 2 hours."
          },
          authorize?: false
        )
        |> Ash.create!()
      end

      # CSAT on the resolved ticket.
      if status == :resolved do
        PawChart.Support.Csat
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            ticket_id: ticket.id,
            agent_id: primary_agent.id,
            score: 5,
            comments: "Very helpful and fast response.",
            channel: :email,
            responded_at: now
          },
          actor: member,
          authorize?: false
        )
        |> Ash.create!()
      end
    end)

    :ok
  end
end
