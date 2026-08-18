defmodule Samen.Scopes.Automation.Blueprint do
  @moduledoc """
  Resource-definition macro for the Automation scope (ADR-039 §3.1; ADR-004 blueprint).

  Object: `workflow` — the E1 rule definition. Org-scoped. NO PII by schema: every
  column is a bounded id / enum / timestamp / name / bounded jsonb of ids+enums+names.
  A workflow **cannot** store a subject attribute value (conditions/actions/webhook
  includes all pass the write-time eligibility oracle, `Samen.Automation.NonPiiPredicates`)
  and the run pipeline carries ids/names only — so automation, the surface class that
  most easily leaks PII, is governed by construction (INV-1).

  ## Kill-switch columns (ADR-039 §8.4 — carried from day one)

  `disabled_by_operator_at` + `disabled_reason` ship in T39 even though the operator
  UI is T42: dispatch honors them from the first run, so T42 delivers surfaces without
  a migration. Two independent switches — tenant pause (`status: :paused`) and operator
  kill (`disabled_by_operator_at`) — both gate dispatch (`status == :active AND
  disabled_by_operator_at IS NULL`).

  ## Schedule scan (ADR-039 §4.1(2))

  ONE AshOban trigger on the resource itself (`:schedule_scan`, explicit
  `scheduler_cron "* * * * *"`): the where-clause selects active schedule workflows
  whose `next_fire_at <= now()`, runs `:dispatch_due` (enqueue + advance) per record.
  Tenant cron is runtime data, so this single `next_fire_at` scan is the
  plain-Oban-compatible shape (not compile-time triggers per rule).

  ## T41 additions — Reminder (E4) + Escalation (E5)

  `define_reminder/5` and `define_escalation/5` (ADR-039 §6/§7) ship the same
  library-authored-blueprint convention: a host materializes each with one macro
  call. `Reminder` is a plain-enum lifecycle (`scheduled -> sent | cancelled`);
  `Escalation` is AshStateMachine-driven (`open -> escalating -> resolved |
  exhausted | cancelled`) — ADR-037 §5.8's OTHER targeted new-resource use
  alongside the E8 Run log. Both carry an AshOban due-scan trigger on queue
  `:automation_timers` (distinct from Workflow's `:automation` queue — timer
  fan-out is a different load shape than rule dispatch).
  """

  # ---------------------------------------------------------------------------
  # Workflow — the E1 rule definition. Org-scoped. No PII by schema.
  # ---------------------------------------------------------------------------
  defmacro define_workflow(module, otp_app, domain, repo, abbrev) do
    # Stable AshOban worker/scheduler module names derived from the host resource
    # module (required so renaming the trigger never leaves dangling jobs).
    resolved = Macro.expand(module, __CALLER__)
    scheduler_mod = Module.concat(resolved, ScheduleScanScheduler)
    worker_mod = Module.concat(resolved, ScheduleScanWorker)

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Automation.Workflow — a tenant-definable automation (ADR-039 §3.1/§4). A
        trigger (`resource_event | schedule | manual`) → condition AND-gate → ordered
        actions. Org-scoped; runs execute as `owner_id` on the tenant plane. No PII by
        schema — conditions/actions key ONLY off condition-eligible attributes
        (enforced at write by `Samen.Automation.NonPiiPredicates`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshOban],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_workflow")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :active, :paused]]
          )

          attribute(:trigger_kind, :atom,
            public?: true,
            default: :resource_event,
            constraints: [one_of: [:resource_event, :schedule, :manual]]
          )

          # The catalog identity (fully-qualified resource module string) of the
          # trigger source. Bounded metadata, not subject data.
          attribute(:resource_key, :string, public?: true)

          # resource_event only.
          attribute(:event, :atom,
            public?: true,
            constraints: [one_of: [:created, :updated, :destroyed]]
          )

          # schedule only.
          attribute(:schedule_cron, :string, public?: true)
          attribute(:next_fire_at, :utc_datetime, public?: true)

          # Bounded jsonb: a list of condition maps (§4.4) and a list of action config
          # maps (§5). Both are ids/enums/names only — the write-time oracle refuses a
          # vaulted/plaintext key.
          attribute(:conditions, {:array, :map}, public?: true, default: [])
          attribute(:actions, {:array, :map}, public?: true, default: [])

          # The execution principal (§4.5) — a bounded id, not a subject reference.
          attribute(:owner_id, :uuid, public?: true)

          # Kill-switch (§8.4) — carried from day one; surfaces are T42.
          attribute(:disabled_by_operator_at, :utc_datetime, public?: true)

          attribute(:disabled_reason, :atom,
            public?: true,
            constraints: [one_of: [:operator, :rate_tripped]]
          )

          # T40 / ADR-039 §5.3 — the webhook action's HMAC signing secret.
          # `public?: false`: never accepted from client input, never selected
          # onto any public projection; `sensitive?: true`: redacted from
          # inspect/logs (the credential-material posture — app-level column
          # sealing is a noted post-1.0 hardening candidate, §5.3). Generated
          # server-side by `Samen.Automation.WebhookSecretGenerate` below.
          attribute(:webhook_secret, :string, public?: false, sensitive?: true)
        end

        validations do
          # INV-1 write-time refusal: conditions + action interpolations key ONLY off
          # condition-eligible (non-PII, non-vaulted) attributes of the target resource.
          validate({Samen.Automation.NonPiiPredicates, []}, on: [:create, :update])
        end

        changes do
          change(Samen.Automation.WebhookSecretGenerate, on: [:create])
        end

        actions do
          defaults([:read, :destroy, create: :*])

          # Tenant-writable update — DELIBERATELY excludes disabled_by_operator_at /
          # disabled_reason (ADR-039 §8.4 T42 addition). The kill columns are an
          # OPERATOR-plane switch; if the generic update accepted them (the old
          # `update: :*` shorthand did), any tenant member could self-un-kill through
          # the ordinary edit form, collapsing the two-switch design into one. Tenant
          # pause (`status: :paused`) stays reachable here — that switch IS
          # tenant-owned (§8.4 "Tenant pause — owner-controlled in the builder").
          update :update do
            accept([
              :name,
              :status,
              :trigger_kind,
              :resource_key,
              :event,
              :schedule_cron,
              :next_fire_at,
              :conditions,
              :actions,
              :owner_id
            ])

            require_atomic?(false)
          end

          # Internal cross-org system read used ONLY by the AshOban :schedule_scan
          # scheduler (bypass-authorized below). The scan is global by design — each
          # due row is dispatched under its OWN org (envelope org_id), so no cross-org
          # data crosses a plane. Not exposed on any tenant surface.
          read :scan_due do
            pagination(keyset?: true, required?: false)
          end

          # System maintenance action driven by the :schedule_scan AshOban trigger.
          # Advances next_fire_at + enqueues a schedule dispatch (Samen.Automation.ScheduleAdvance).
          update :dispatch_due do
            accept([])
            require_atomic?(false)
            change(Samen.Automation.ScheduleAdvance)
          end

          # ADR-039 §8.4 — the OPERATOR half of the two-switch kill (T42). Sets
          # `disabled_by_operator_at` + `disabled_reason` (`:operator`, human-invoked
          # from the operator health view; `:rate_tripped`, breaker-invoked, §4.7(3)).
          # FAIL-SAFE / idempotent: killing an already-killed workflow is a no-op that
          # preserves the ORIGINAL kill timestamp/reason (never re-stamps, never
          # errors) — calling kill twice has the same effect as calling it once.
          # Authorization is NOT an Ash policy here (bypassed below, like
          # `:dispatch_due`) because the real actor is cross-org by design (the SaaS
          # operator killing ANY tenant's workflow, the `Samen.OperatorPlane` shape) —
          # a plain `OrgScope` policy cannot express "any org, gated by operator RBAC
          # instead". The RBAC gate is enforced in application code BEFORE the write,
          # the same `may_*?/1`-then-`authorize?: false` idiom `Samen.OperatorPlane`
          # already uses (see `Samen.Automation.Health`).
          update :operator_kill do
            accept([])
            require_atomic?(false)

            argument(:reason, :atom,
              constraints: [one_of: [:operator, :rate_tripped]],
              default: :operator
            )

            change(fn changeset, _ctx ->
              if is_nil(Ash.Changeset.get_data(changeset, :disabled_by_operator_at)) do
                changeset
                |> Ash.Changeset.force_change_attribute(:disabled_by_operator_at, DateTime.utc_now())
                |> Ash.Changeset.force_change_attribute(
                  :disabled_reason,
                  Ash.Changeset.get_argument(changeset, :reason)
                )
              else
                # Already killed — idempotent no-op, keep the original stamp.
                changeset
              end
            end)
          end

          # ADR-039 §8.4 re-arm — explicit operator (or, for rate trips, tenant-owner
          # per §4.7(3)) action; never automatic. Idempotent: re-arming an
          # already-active workflow is a no-op.
          update :operator_rearm do
            accept([])
            require_atomic?(false)
            change(set_attribute(:disabled_by_operator_at, nil))
            change(set_attribute(:disabled_reason, nil))
          end
        end

        oban do
          triggers do
            trigger :schedule_scan do
              action(:dispatch_due)
              queue(:automation)
              scheduler_cron("* * * * *")
              scheduler_module_name(unquote(scheduler_mod))
              worker_module_name(unquote(worker_mod))
              read_action(:scan_due)
              worker_read_action(:scan_due)
              stream_with(:full_read)
              actor_persister(:none)
              max_attempts(1)

              # Field refs via ref/1 (a literal call) rather than bare identifiers, so
              # the expr survives this blueprint's macro-quote hygiene intact.
              where(
                expr(
                  ^ref(:status) == :active and ^ref(:trigger_kind) == :schedule and
                    not is_nil(^ref(:next_fire_at)) and ^ref(:next_fire_at) <= now()
                )
              )
            end
          end
        end

        policies do
          # The schedule scan runs the system :dispatch_due action with no actor —
          # bypass authorization (it only advances next_fire_at + enqueues, streamed
          # per-record by AshOban, never crossing orgs).
          bypass action([:dispatch_due, :scan_due]) do
            authorize_if(always())
          end

          # ADR-039 §8.4 operator kill/re-arm — bypassed here (like :dispatch_due)
          # because the real actor is CROSS-ORG (the SaaS operator, not a tenant
          # member of this workflow's org) — an OrgScope policy cannot express that.
          # The RBAC gate (`Samen.Automation.Health.may_manage?/1`, checked BEFORE
          # the write, `authorize?: false`) is the enforcement point — the exact
          # `Samen.OperatorPlane` idiom (application-code gate + explicit-scope
          # bypass read/write) already used for the operator CRM. Both callers of
          # these actions run authorize?: false themselves (the LiveView action
          # through `Health.kill/3`/`Health.rearm/3`; the rate breaker internally) —
          # this bypass documents that they are NEVER reachable through a public,
          # actor-checked Ash API.
          bypass action([:operator_kill, :operator_rearm]) do
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Reminder — the E4 first-class reminder (ADR-039 §6; T41). Distinct from
  # Notification (its own `scheduled -> sent | cancelled` lifecycle; the
  # Notification is only the delivery artifact created at fire time). `note` is
  # user-authored freeform => vault-routed (the `Notification.rendered_body`
  # precedent). A plain bounded enum drives state (NOT AshStateMachine — ADR-037
  # §5.8's targeted-adoption list is Run + Escalation only); firing uses an
  # app-level idempotent state-guard (`Ash.Changeset.filter/2`, the SlaBreachWorker
  # `breached = false` discipline) so a concurrent duplicate scan is a no-op.
  # ---------------------------------------------------------------------------
  defmacro define_reminder(module, otp_app, domain, repo, abbrev) do
    resolved = Macro.expand(module, __CALLER__)
    scheduler_mod = Module.concat(resolved, ReminderDueScheduler)
    worker_mod = Module.concat(resolved, ReminderDueWorker)

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Automation.Reminder — a first-class "remind me about X at T" (ADR-039 §6;
        E4). Distinct from `Notification`: this row IS the future intent
        (`scheduled -> sent | cancelled`); firing emits a `Notification` as the
        delivery artifact (`event_type: "reminder_due"`), feeding digest batching
        with zero new plumbing. `note` is vault-routed (INV-1) — plaintext never
        at rest, tenant plane resolves clear, operator plane masks.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshOban],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_reminder")
          repo(unquote(repo))
        end

        attributes do
          attribute(:recipient_id, :uuid, public?: true, allow_nil?: false)
          attribute(:subject_ref, :string, public?: true, allow_nil?: false)
          attribute(:remind_at, :utc_datetime, public?: true, allow_nil?: false)

          attribute(:source, :atom,
            public?: true,
            default: :user,
            constraints: [one_of: [:user, :automation, :system]]
          )

          attribute(:state, :atom,
            public?: true,
            default: :scheduled,
            constraints: [one_of: [:scheduled, :sent, :cancelled]]
          )

          attribute(:sent_at, :utc_datetime, public?: true)
        end

        pii do
          vault(:pii_note)
          pii_attribute(:note, :string, vault: :pii_note)
          reveal(:reveal_reminder)
        end

        actions do
          defaults([:read, :destroy])

          create :schedule do
            accept([:org_id, :recipient_id, :subject_ref, :remind_at, :note, :source])
          end

          update :snooze do
            accept([:remind_at])
            require_atomic?(false)
          end

          update :cancel do
            accept([])
            require_atomic?(false)
            change(set_attribute(:state, :cancelled))
          end

          # Internal cross-org system read used ONLY by the AshOban :reminder_due
          # scheduler (bypass-authorized below) — each due row fires under its OWN
          # org (never cross-plane).
          read :due_scan do
            pagination(keyset?: true, required?: false)
          end

          # System maintenance action driven by the :reminder_due AshOban trigger.
          update :fire do
            accept([])
            require_atomic?(false)
            change(Samen.Automation.ReminderFire)
          end

          action :reveal_reminder, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_reminder,
                label: :note
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        oban do
          triggers do
            trigger :reminder_due do
              action(:fire)
              queue(:automation_timers)
              scheduler_cron("* * * * *")
              scheduler_module_name(unquote(scheduler_mod))
              worker_module_name(unquote(worker_mod))
              read_action(:due_scan)
              worker_read_action(:due_scan)
              stream_with(:full_read)
              actor_persister(:none)
              max_attempts(3)

              where(
                expr(
                  ^ref(:state) == :scheduled and ^ref(:remind_at) <= now()
                )
              )
            end
          end
        end

        policies do
          bypass action([:fire, :due_scan]) do
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_reminder) do
            authorize_if(always())
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Escalation — the E5 generic escalation primitive (ADR-039 §7; T41). Lifecycle
  # driven by AshStateMachine (ADR-037 §5.8's OTHER targeted new-resource use,
  # alongside E8 Run): `open -> escalating -> resolved | exhausted | cancelled`.
  # SLA-breach and dunning become its first CLIENTS via adoption seams (§7.4) —
  # their domain logic is untouched; only their attention path routes here.
  # ---------------------------------------------------------------------------
  defmacro define_escalation(module, otp_app, domain, repo, abbrev) do
    resolved = Macro.expand(module, __CALLER__)
    scheduler_mod = Module.concat(resolved, EscalationDueScheduler)
    worker_mod = Module.concat(resolved, EscalationDueWorker)

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Automation.Escalation — the E5 generic escalation primitive (ADR-039 §7).
        `{org_id, kind, dedupe_key}` idempotent-by-dedupe (open advances a
        non-terminal match rather than duplicating). Owns *attention* (chain
        walking + notification emission) only — client domain truth (SLA breach
        flags, dunning cases) lives entirely OUTSIDE this resource.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshOban, AshStateMachine],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_escalation")
          repo(unquote(repo))
        end

        state_machine do
          initial_states([:open])
          default_initial_state(:open)

          transitions do
            # advance_step's `to` list carries BOTH legal targets — the change
            # module (Samen.Automation.EscalationAdvance) picks the one matching
            # whether a further chain step remains, via
            # `AshStateMachine.transition_state/2` (a runtime function, not the
            # compile-time `transition_state/1` builtin).
            transition(:advance_step, from: [:open, :escalating], to: [:escalating, :exhausted])
            transition(:resolve, from: [:open, :escalating], to: :resolved)
            transition(:cancel, from: [:open, :escalating], to: :cancelled)
          end
        end

        attributes do
          attribute(:kind, :string, public?: true, allow_nil?: false)
          attribute(:dedupe_key, :string, public?: true, allow_nil?: false)
          attribute(:subject_ref, :string, public?: true, allow_nil?: false)
          attribute(:deadline_at, :utc_datetime, public?: true, allow_nil?: false)

          # Bounded jsonb: [{"after_minutes", "recipient", "channel"}, ...] — ids/
          # enums/names only (§7.2). nil/[] at create normalizes to the default
          # single-step org chain.
          attribute(:chain, {:array, :map}, public?: true, default: [], allow_nil?: true)

          attribute(:current_step, :integer, public?: true, default: 0)
          attribute(:next_action_at, :utc_datetime, public?: true)
          attribute(:resolved_at, :utc_datetime, public?: true)

          # Pre-declare the AshStateMachine state attribute so AbbrevStorage
          # prefixes its physical column (the ADR-037 §5.8 C2 self-qualifying-
          # storage duty — the Approval precedent).
          attribute(:state, :atom,
            allow_nil?: false,
            default: :open,
            public?: true,
            writable?: false,
            constraints: [one_of: [:open, :escalating, :resolved, :exhausted, :cancelled]]
          )
        end

        actions do
          defaults([:read])

          create :open do
            accept([:org_id, :kind, :dedupe_key, :subject_ref, :deadline_at, :chain])

            change(fn changeset, _ctx ->
              chain =
                case Ash.Changeset.get_attribute(changeset, :chain) do
                  chain when chain in [nil, []] ->
                    [%{"after_minutes" => 0, "recipient" => "org", "channel" => "in_app"}]

                  chain ->
                    chain
                end

              deadline_at = Ash.Changeset.get_attribute(changeset, :deadline_at)

              changeset
              |> Ash.Changeset.force_change_attribute(:chain, chain)
              |> Ash.Changeset.force_change_attribute(:current_step, 0)
              |> Ash.Changeset.force_change_attribute(:next_action_at, deadline_at)
            end)
          end

          # Advances the deadline on an existing non-terminal escalation
          # (idempotent-by-dedupe re-open/advance, §7.2). Only re-mirrors
          # next_action_at when step 0 has not yet fired (current_step == 0) —
          # a chain already walking keeps its own progression.
          update :refresh do
            accept([:deadline_at])
            require_atomic?(false)

            change(fn changeset, _ctx ->
              if Ash.Changeset.get_data(changeset, :current_step) == 0 do
                case Ash.Changeset.get_attribute(changeset, :deadline_at) do
                  nil -> changeset
                  deadline_at -> Ash.Changeset.force_change_attribute(changeset, :next_action_at, deadline_at)
                end
              else
                changeset
              end
            end)
          end

          # Internal cross-org system read used ONLY by the AshOban
          # :escalation_due scheduler (bypass-authorized below).
          read :due_scan do
            pagination(keyset?: true, required?: false)
          end

          # System maintenance action driven by the :escalation_due AshOban
          # trigger — walks one chain step (Samen.Automation.EscalationAdvance).
          update :advance_step do
            accept([])
            require_atomic?(false)
            change(Samen.Automation.EscalationAdvance)
          end

          update :resolve do
            accept([])
            require_atomic?(false)
            change(set_attribute(:resolved_at, &DateTime.utc_now/0))
            change(transition_state(:resolved))
          end

          update :cancel do
            accept([])
            require_atomic?(false)
            change(set_attribute(:resolved_at, &DateTime.utc_now/0))
            change(transition_state(:cancelled))
          end
        end

        oban do
          triggers do
            trigger :escalation_due do
              action(:advance_step)
              queue(:automation_timers)
              scheduler_cron("* * * * *")
              scheduler_module_name(unquote(scheduler_mod))
              worker_module_name(unquote(worker_mod))
              read_action(:due_scan)
              worker_read_action(:due_scan)
              stream_with(:full_read)
              actor_persister(:none)
              max_attempts(3)

              where(
                expr(
                  ^ref(:state) in [:open, :escalating] and not is_nil(^ref(:next_action_at)) and
                    ^ref(:next_action_at) <= now()
                )
              )
            end
          end
        end

        policies do
          bypass action([:advance_step, :due_scan]) do
            authorize_if(always())
          end

          # The engine's own writes (open/refresh/resolve/cancel) run
          # authorize?: false from Samen.Automation.Escalate — a trusted kernel
          # API, the Approvals/Grants precedent. Tenant-surface reads stay
          # org-scoped.
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Run — the E8 run log (ADR-039 §3.1/§8.1; T42). Records EVERY dispatch
  # outcome — `fired` (-> `succeeded | failed`) or `skipped` (a bounded reason).
  # No PII by schema: every column is a bounded id/enum/timestamp/name/number or
  # a bounded jsonb outcome list carrying per-action `{index, kind, status,
  # error_kind, duration_ms}` — ids/enums/numbers ONLY, never a subject
  # attribute value (the same discipline Workflow's `conditions`/`actions`
  # already hold). State machine (ADR-037 §5.8's OTHER targeted new-resource
  # use, alongside Escalation): `queued -> running -> succeeded | failed |
  # skipped`. Written EXCLUSIVELY by the kernel pipeline
  # (`Samen.Automation.RunRecord`, called from `RunWorker`/`DispatchWorker`/
  # `Breaker`) — never a tenant or operator UI write; both planes only READ it
  # (tenant: per-workflow run list, T118; operator: the health view, T42).
  # ---------------------------------------------------------------------------
  defmacro define_run(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Automation.Run — the E8 run log (ADR-039 §8.1; T42). One row per dispatch
        outcome. No PII by schema — ids/enums/timestamps/bounded numeric jsonb
        only; passes the same "no pii_ column, ever" bar the token-blind
        aggregate plane holds (INV-1/INV-2), proven directly against
        `information_schema` (this resource is intentionally NOT
        `Samen.Aggregate.Resource` — it is a normal org-scoped OLTP resource
        that simply, by construction, carries no PII column to begin with).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshStateMachine],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_run")
          repo(unquote(repo))
        end

        state_machine do
          initial_states([:queued])
          default_initial_state(:queued)

          # AshStateMachine's positional `transition(action, ...)` arg names the
          # Ash ACTION that performs it (`AshStateMachine.Verifiers.
          # VerifyTransitionActions` requires a same-named create/update action
          # to exist) — it is not an independent transition label. `:finalize`'s
          # target is data-dependent (succeeded/failed/skipped), so THREE
          # entries share the SAME action name with different `to:` — the
          # runtime `AshStateMachine.transition_state/2` call inside
          # `Samen.Automation.RunFinalize` picks whichever entry's `from`/`to`
          # matches the actual old-state/target pair (exactly the Escalation
          # `:advance_step` precedent, generalized from one entry with a `to:`
          # list to several entries with one target each).
          transitions do
            transition(:start, from: :queued, to: :running)
            transition(:finalize, from: :running, to: :succeeded)
            transition(:finalize, from: :running, to: :failed)
            # A run can be recorded skipped straight from :queued (killed/loop/
            # depth_exceeded/owner_unavailable/invalid_conditions/
            # conditions_unmet — decided BEFORE any action ever fires) or, in
            # principle, from :running (kept for forward-compat; unused today).
            transition(:finalize, from: [:queued, :running], to: :skipped)
          end
        end

        attributes do
          attribute(:workflow_id, :uuid, public?: true, allow_nil?: false)

          # Tier-2 durable dedupe (ADR-039 §4.6): sha256(workflow_id <> event_id),
          # unique-indexed. A second insert for the same (workflow, event) is a
          # no-op conflict — `Samen.Automation.RunRecord.open!/2` finds the
          # existing row instead of erroring.
          attribute(:dispatch_key, :string, public?: true, allow_nil?: false)

          attribute(:trigger_kind, :atom,
            public?: true,
            constraints: [one_of: [:resource_event, :schedule, :manual]]
          )

          attribute(:subject_ref, :string, public?: true)
          attribute(:depth, :integer, public?: true, default: 0)

          # Bounded jsonb: the ordered per-action outcome list — ids/enums/
          # numbers only (ADR-039 §5.1 outcome shape), never a subject value.
          attribute(:outcome, {:array, :map}, public?: true, default: [])

          attribute(:started_at, :utc_datetime, public?: true)
          attribute(:finished_at, :utc_datetime, public?: true)
          attribute(:duration_ms, :integer, public?: true)

          # The bounded skip-reason set (ADR-039 §8.1) + the closed set of
          # fire-time action error kinds (ADR-039 §5.2's 8 actions +
          # `Compile.ActionStep`'s own `:unknown_action_kind`/`:raised`) +
          # `:action_failed`/`:internal_error` generic fallbacks. A CLOSED
          # enum, matching every other bounded column here — never a
          # freeform/inspected error string (`Samen.Automation.RunRecord`
          # enforces the same closed set defensively at the persistence
          # boundary so an unrecognized value degrades to `:action_failed`
          # rather than being rejected/lost).
          attribute(:error_kind, :atom,
            public?: true,
            constraints: [
              one_of: [
                # Skip reasons (§8.1).
                :conditions_unmet,
                :invalid_conditions,
                :killed,
                :loop,
                :depth_exceeded,
                :rate_tripped,
                :owner_unavailable,
                # Generic fired-but-failed buckets.
                :action_failed,
                :internal_error,
                :raised,
                :unknown_action_kind,
                # The 8 actions' fire-time error kinds (ADR-039 §5.2/§5.3).
                :adapter_unconfigured,
                :escalate_unwired,
                :https_required,
                :invalid_assigns,
                :invalid_at_attribute,
                :invalid_attribute,
                :invalid_attrs,
                :invalid_chain,
                :invalid_config,
                :invalid_deadline_minutes,
                :invalid_event_type,
                :invalid_include,
                :invalid_offset_minutes,
                :invalid_recipient,
                :invalid_schedule,
                :invalid_scheme,
                :invalid_tag,
                :invalid_template_key,
                :invalid_to,
                :invalid_url,
                :invalid_user_id,
                :missing_resource_key,
                :missing_schedule,
                :no_automation_module,
                :no_recipient,
                :no_subject_record,
                :no_tag_surface,
                :no_webhook_secret,
                :not_found,
                :nxdomain,
                :reminder_unwired,
                :ssrf_blocked,
                :suppressed,
                :unauthorized,
                :unknown_resource,
                :write_failed
              ]
            ]
          )

          # Pre-declare the AshStateMachine state attribute (the Escalation
          # precedent) so AbbrevStorage prefixes its physical column.
          attribute(:state, :atom,
            allow_nil?: false,
            default: :queued,
            public?: true,
            writable?: false,
            constraints: [one_of: [:queued, :running, :succeeded, :failed, :skipped]]
          )
        end

        actions do
          defaults([:read])

          # Opens the run row (RunRecord.open!/2) — :queued, timing not yet
          # started. accept-only, no PII-shaped attribute exists to accept.
          create :record do
            accept([:org_id, :workflow_id, :dispatch_key, :trigger_kind, :subject_ref, :depth])

            # Tier-2 dedupe: a concurrent duplicate dispatch racing the SAME
            # (workflow_id, event_id) upserts onto the existing row instead of
            # violating the unique index (durable dedupe across the Oban
            # job-pruning horizon, ADR-039 §4.6).
            upsert?(true)
            upsert_identity(:unique_dispatch_key)
            upsert_fields([])
          end

          update :start do
            accept([])
            require_atomic?(false)
            change(set_attribute(:started_at, &DateTime.utc_now/0))
            change(transition_state(:running))
          end

          # Terminal transition — target state is data-dependent (succeeded /
          # failed / skipped), so this uses the RUNTIME
          # `AshStateMachine.transition_state/2` function via
          # `Samen.Automation.RunFinalize` (the EscalationAdvance precedent),
          # not the compile-time `transition_state/1` DSL builtin.
          update :finalize do
            accept([:outcome, :error_kind])
            require_atomic?(false)

            argument(:to, :atom,
              allow_nil?: false,
              constraints: [one_of: [:succeeded, :failed, :skipped]]
            )

            change(Samen.Automation.RunFinalize)
          end
        end

        identities do
          identity(:unique_dispatch_key, [:dispatch_key])
        end

        policies do
          # Written EXCLUSIVELY by the kernel pipeline via authorize?: false
          # (RunRecord/RunWorker/DispatchWorker/Breaker) — never a public write
          # surface. Reads are org-scoped for both planes that consume this log.
          bypass action_type([:create, :update]) do
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end
        end
      end
    end
  end
end
