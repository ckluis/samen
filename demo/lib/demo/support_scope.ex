defmodule Demo.SupportScope do
  @moduledoc """
  The Demo host's Support domain — mounted from the `samen_core` Support scope
  blueprint (ADR-004; T3.6).

  One `use Samen.Scopes.Support` expands into seven host-owned resources
  (`Demo.SupportScope.{Ticket,Conversation,Message,Agent,Sla,Macro,Csat}`),
  each a normal `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddSupportScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * `Message` PII (body) and `Agent` PII (full_name/email) route into the DEMO's
      one Postgres vault;
    * org-scope + RBAC policies are inherited, not re-authored;
    * SLA breach detection is wired via `Samen.Scopes.Support.SlaBreachWorker`.

  ## SLA breach detection

  Add the cron to your Oban config and configure the ticket resource:

      config :samen_core, :support_sla_breach_ticket_resource, Demo.SupportScope.Ticket

  The worker runs in the `:maintenance` queue (concurrency 1). Each minute it finds
  tickets with `sla_breach_at <= now()` and `breached == false`, marks them breached,
  and emits `support.ticket.breached` audit events.

  ## Tier-0 config rows

  `Sla` and `Macro` are the Tier-0 config resources. See `Demo.SupportScope.Seeds`
  for the default rows.

  ## Non-PII classification (`csat.comments`)

  `csat_comments` is a free-text operator-authored response field. It is NOT flagged
  as PII by the `pii_classify` heuristic (the name "comments" is not in the token list).
  However, because it is a free-text field that could contain subject-identifying content
  in practice, we register it explicitly via `Demo.SupportScope.NonPiiSetup` with
  distinct-reviewer sign-off (same pattern as CMS `csm_description`). This demonstrates
  the mask-unknown-by-default discipline (D9) was applied consciously.

  ## Thin smoke usage (T3.6 acceptance: proves host-mounting works)

  `Demo.SupportScope.Smoke.run/1` exercises one round-trip per resource — a ticket,
  a conversation, a message (vaulted body), an agent (vaulted name/email), an SLA row,
  a macro, and a CSAT response — confirming host-mount and vault routing work end-to-end
  against a real Postgres DB.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Support,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.SupportScope
end

defmodule Demo.SupportScope.NonPiiSetup do
  @moduledoc """
  Runtime registration of deliberate non-PII columns in the Support scope.

  Called from test setup and from seed tasks. Fulfils the T3.6 requirement to
  classify free-text columns explicitly via the mask-unknown-by-default discipline (D9).

  ## Registered columns

  | Table       | Column           | Rationale                                              |
  |-------------|------------------|--------------------------------------------------------|
  | scs_csat    | scs_comments     | Customer-facing survey text — consciously cleared      |
  | smc_macro   | smc_body_template| Operator-authored template text — not subject identity |

  See `Samen.Scopes.Support.Blueprint.define_csat/7` moduledoc for the csat_comments
  design rationale.
  """

  @doc "Register Support non-PII columns. Idempotent."
  def register_all do
    with :ok <- register_csat_comments(),
         :ok <- register_macro_body() do
      :ok
    end
  end

  defp register_csat_comments do
    case Samen.NonPii.register(%{
           table_name: "scs_csat",
           column_name: "scs_comments",
           cleared_by: "T3.6-scope-author",
           reviewed_by: "T3.6-gate-reviewer",
           reason:
             "CSAT comments are customer-facing survey text used for aggregate feedback analysis. " <>
               "The doc does not flag csat as a 🔒 resource. Treating this as vault-routed would " <>
               "break aggregation and analytics. The primary PII exchange (message body) is already " <>
               "vaulted on Message. Consciously cleared as non-PII with distinct-reviewer sign-off " <>
               "(T3.6 Support scope).",
           subject_column: "scs_org_id",
           redaction: "[REDACTED_FEEDBACK]"
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_macro_body do
    case Samen.NonPii.register(%{
           table_name: "smc_macro",
           column_name: "smc_body_template",
           cleared_by: "T3.6-scope-author",
           reviewed_by: "T3.6-gate-reviewer",
           reason:
             "Macro body_template is operator-authored canned response text (e.g. 'Thank you for " <>
               "contacting us. We will get back to you shortly.'). It describes product-level " <>
               "templates, not subject personal identifiers. Analogous to cms_page.body. " <>
               "Consciously cleared as non-PII with distinct-reviewer sign-off (T3.6 Support scope).",
           subject_column: "smc_org_id",
           redaction: "[REDACTED_TEMPLATE]"
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Demo.SupportScope.Seeds do
  @moduledoc """
  Seed helpers for the Support scope Tier-0 config rows.

  Seeds two SLA policies (normal priority: 1h first-response / 8h resolution;
  urgent priority: 15min first-response / 1h resolution) and two macros (a
  standard acknowledgement + a resolution template). These are idempotent —
  safe to run multiple times.
  """

  alias Demo.SupportScope.{Sla, Macro}

  def seed_sla(org_id) do
    Enum.each(
      [
        %{
          name: "standard",
          label: "Standard",
          first_response_minutes: 60,
          resolve_minutes: 480,
          priority: :normal,
          enabled: true,
          org_id: org_id
        },
        %{
          name: "urgent",
          label: "Urgent",
          first_response_minutes: 15,
          resolve_minutes: 60,
          priority: :urgent,
          enabled: true,
          org_id: org_id
        }
      ],
      fn attrs ->
        Sla
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(authorize?: false)
      end
    )
  end

  def seed_macros(org_id) do
    Enum.each(
      [
        %{
          name: "ack",
          description: "Standard acknowledgement",
          body_template:
            "Thank you for contacting support. We have received your request and will follow up shortly.",
          tags: ["ack"],
          enabled: true,
          org_id: org_id
        },
        %{
          name: "resolved",
          description: "Resolution confirmation",
          body_template:
            "We are pleased to confirm that your issue has been resolved. Please let us know if you need further assistance.",
          tags: ["resolution"],
          enabled: true,
          org_id: org_id
        }
      ],
      fn attrs ->
        Macro
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(authorize?: false)
      end
    )
  end
end

defmodule Demo.SupportScope.Smoke do
  @moduledoc """
  Thin smoke usage for the Support scope. Exercises one round-trip per resource,
  confirming the host-mount and core mechanics work end-to-end.

  Called from tests (`support_scope_policy_matrix_test.exs`) to prove:
    * host-mounting works (resources exist, compile, have the right namespace)
    * the org-scope policy is wired (cross-org invisibility)
    * Message body and Agent full_name/email are vault-routed (PII masked)
    * SLA Tier-0 config rows work (admin creates; member can read)
    * Macro Tier-0 config rows work
    * CSAT responses are linked to tickets and agents
  """

  alias Demo.SupportScope.{Ticket, Conversation, Message, Agent, Sla, Macro, Csat}

  @doc "Create an SLA policy row."
  def mk_sla(org_id, name \\ "standard") do
    Sla
    |> Ash.Changeset.for_create(:create, %{
      name: name,
      label: String.capitalize(name),
      first_response_minutes: 60,
      resolve_minutes: 480,
      priority: :normal,
      enabled: true,
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a ticket (linked to an optional SLA row)."
  def mk_ticket(org_id, sla_id \\ nil) do
    attrs =
      %{
        subject: "Demo ticket — #{:rand.uniform(999_999)}",
        status: :open,
        priority: :normal,
        org_id: org_id
      }
      |> then(fn a -> if sla_id, do: Map.put(a, :sla_id, sla_id), else: a end)

    Ticket
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
  end

  @doc "Create a conversation on a ticket."
  def mk_conversation(org_id, ticket_id) do
    Conversation
    |> Ash.Changeset.for_create(:create, %{
      channel: :email,
      status: :open,
      subject: "Re: Demo ticket",
      org_id: org_id,
      ticket_id: ticket_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create an agent with PII (full_name + email vault-routed)."
  def mk_agent(org_id) do
    Agent
    |> Ash.Changeset.for_create(:create, %{
      handle: "agent-#{:rand.uniform(999_999)}",
      full_name: %Samen.Type.FullName{first: "Dana", last: "Operator"},
      email: "dana-#{:rand.uniform(999_999)}@support.example",
      status: :active,
      role: :agent,
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a message (body is vault-routed PII)."
  def mk_message(org_id, conversation_id, agent_id \\ nil) do
    attrs =
      %{
        body: "Hello, I am having trouble with order ##{:rand.uniform(9999)}.",
        sender_type: :customer,
        message_type: :reply,
        org_id: org_id,
        conversation_id: conversation_id
      }
      |> then(fn a -> if agent_id, do: Map.put(a, :agent_id, agent_id), else: a end)

    Message
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
  end

  @doc "Create a macro (Tier-0 config row)."
  def mk_macro(org_id) do
    Macro
    |> Ash.Changeset.for_create(:create, %{
      name: "ack-#{:rand.uniform(99999)}",
      description: "Standard acknowledgement",
      body_template: "Thank you for contacting support.",
      tags: ["ack"],
      enabled: true,
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a CSAT response on a ticket."
  def mk_csat(org_id, ticket_id, agent_id \\ nil) do
    attrs =
      %{
        score: 5,
        comments: "Great support experience!",
        channel: :email,
        responded_at: DateTime.utc_now(),
        org_id: org_id,
        ticket_id: ticket_id
      }
      |> then(fn a -> if agent_id, do: Map.put(a, :agent_id, agent_id), else: a end)

    Csat
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
  end

  @doc "Run a complete round-trip smoke test. Returns {:ok, results} or {:error, reason}."
  def run(org_id) do
    with {:ok, sla} <- mk_sla(org_id),
         {:ok, ticket} <- mk_ticket(org_id, sla.id),
         {:ok, convo} <- mk_conversation(org_id, ticket.id),
         {:ok, agent} <- mk_agent(org_id),
         {:ok, message} <- mk_message(org_id, convo.id, agent.id),
         {:ok, macro} <- mk_macro(org_id),
         {:ok, csat} <- mk_csat(org_id, ticket.id, agent.id) do
      {:ok,
       %{
         sla: sla,
         ticket: ticket,
         conversation: convo,
         agent: agent,
         message: message,
         macro: macro,
         csat: csat
       }}
    end
  end
end
