defmodule Samen.AI.Agent.Kill do
  @moduledoc """
  `Samen.AI.Agent.Kill` — the DURABLE, per-{org, agent-definition} kill switch
  (ADR-047 §6, batch A5; the A2/A3 residual `Samen.AI.Agent.Breaker` carried forward
  in its own moduledoc: *"A durable per-definition kill column is A5's
  operator-surface residual"*).

  ## What it replaces: the cross-tenant blast radius

  A2/A3 counted the rate trip PER ORG but threw the HOST-LEVEL switch: one org
  crossing its own 60-runs/hour threshold stopped agent runs for EVERY org on the
  host, until a human re-armed. A5 narrows the trip to exactly the tenant and the
  agent definition that caused it — one row per `{org_id, agent}` — so a noisy tenant
  no longer halts the fleet. The host-level lever still exists (it is the operator's
  global emergency stop, `Samen.AI.Agent.Breaker.kill/2`), but **nothing automatic
  throws it any more**: a rate trip writes a row HERE.

  ## Durable, not node-lifetime

  The A2 runtime switch lived in `:persistent_term` — node-lifetime state that a
  restart silently cleared. This is a real table row: it survives a restart, a
  redeploy, and a rolling node replacement, and it is readable by the operator
  surface as state rather than reconstructed from a log. `killed_at` / `rearmed_at`
  are both retained, so the row is its own history: a re-armed definition keeps the
  record of having been killed, and a re-trip after a re-arm is a fresh `killed_at`
  past the `rearmed_at`.

  ## Token-only (ADR-047 §6 / INV-1)

  `org_id`, the agent definition NAME (an authored identifier from the validated
  `use Samen.AI.Agent` definition — never tenant data), a bounded `reason` enum
  string (`operator` | `rate_tripped` | `provider_tripped`), the acting operator's
  bounded id, and two timestamps. No prompt text, no tenant attribute, no vault
  token — there is no PII column here to reach, the
  `Samen.Web.Operator.WebhookDlqLive` / `AutomationHealthLive` posture.

  Writes are kernel-only (`Samen.AI.Agent.Breaker` / `Samen.AI.Agent.Health` — the
  Run/Turn posture); tenant reads are org-scoped through `Samen.Policy.OrgScope`, so
  a tenant can see that ITS OWN agent is stopped and never another org's.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "akl"

  postgres do
    table("ai_agent_kill")
    repo(Application.compile_env(:samen_core, :samen_ai_agent_kill_repo, SamenCore.TestRepo))
  end

  attributes do
    # The agent DEFINITION name (`definition().name` — authored, validated, bounded).
    attribute(:agent, :string, public?: true, allow_nil?: false)

    # A bounded trip reason (closed set — `Samen.AI.Agent.Breaker.bounded_reason/1`
    # degrades anything unexpected to "operator" rather than rejecting a KILL, the
    # `safe_error_kind/1` posture: a switch must never fail to throw because its label
    # was unfamiliar). Stored as plain text, the `arn_state` precedent, so the set can
    # widen with no migration.
    attribute(:reason, :string, public?: true, allow_nil?: false)

    attribute(:killed_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:killed_by, :string, public?: true)

    # Non-nil AND at-or-after `killed_at` ⇒ the definition is live again. Retained (never
    # deleted) so the row carries its own history.
    attribute(:rearmed_at, :utc_datetime_usec, public?: true)
    attribute(:rearmed_by, :string, public?: true)
  end

  identities do
    # ONE row per {org, definition}: the trip is an upsert, so a repeated trip is
    # idempotent rather than a growing pile of rows (the Automation.Breaker trip
    # discipline, made durable).
    identity(:org_agent, [:org_id, :agent])
  end

  actions do
    defaults([:read])

    create :trip do
      description(
        "Throw the durable per-definition kill for {org, agent}. Upserts the one row: " <>
          "a repeated trip is idempotent, and a trip AFTER a re-arm clears rearmed_at."
      )

      accept([:org_id, :agent, :reason, :killed_at, :killed_by])
      upsert?(true)
      upsert_identity(:org_agent)
      upsert_fields([:reason, :killed_at, :killed_by, :rearmed_at, :rearmed_by])

      change(set_attribute(:rearmed_at, nil))
      change(set_attribute(:rearmed_by, nil))
    end

    update :rearm do
      description("Explicit operator re-arm — trips NEVER self-heal (ADR-047 §6).")
      accept([:rearmed_at, :rearmed_by])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Kernel-only writes (the Samen.AI.Agent.Run posture): Breaker/Health are the only
    # authors, and both gate on the operator role in application code before writing.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end
end
