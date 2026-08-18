defmodule Samen.Scopes.Outreach.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Outreach** scope (spec §I2, T75; ADR-004
  blueprint) — "CRM sequences actually send". This is a genuinely NEW capability,
  not a resurfacing: today's Marketing scope (ADR-011) covers single-blast
  campaigns; Outreach adds tenant-defined MULTI-STEP sequences that enroll a CRM
  contact and progress them through timed steps, sending through the SAME C2
  delivery chokepoint the rest of the platform uses (`Samen.Delivery.Chokepoint`,
  T28) — never a parallel send path.

  Objects: `sequence · enrollment · step_send`. NONE of the three carry PII: a
  `Sequence`'s `steps` are tenant-AUTHORED template config (subject/body strings a
  human wrote, not subject data — same non-PII posture as `Marketing.Template`);
  an `Enrollment.person_id` is an OPAQUE reference to a CRM contact (the same
  "plain uuid, no FK" posture `Samen.Scopes.Mailbox.MailMessage.company_id` uses),
  never the identity data itself; a `StepSend` carries only bounded ids/enums.

  ## Independent of CRM (no FK, mirrors the Mailbox precedent)

  `Enrollment.person_id` is a plain `:uuid` attribute, NOT an Ash relationship
  into the CRM scope's `Person` resource. This scope therefore mounts
  independently of CRM (exactly like `Samen.Scopes.Mailbox` mounts independently
  of it) — a host without CRM can still run sequences against whatever contact
  ids it supplies; a host WITH CRM enrolls real `Person` ids. Org-pinning for
  every read that touches `person_id` is enforced by explicit `org_id` filters in
  application code (`Samen.Sequences`), never by relationship traversal.

  ## Sends ONLY through the C2 chokepoint (never a parallel path)

  A due step is queued (`StepSend`, `status: :queued`) and handed to
  `Samen.Sequences.SendWorker`, which builds a token-only `Samen.Delivery.Message`
  and calls `Samen.Delivery.Chokepoint.send/2` — the SAME single chokepoint
  `Samen.Scopes.Marketing.SendWorker` / `Samen.Delivery.Lifecycle.EmailWorker` /
  `Samen.Delivery.AuthMailer` route through (T28's anti-tautology grep for
  `.deliver(` outside the chokepoint covers this module too: it never calls an
  adapter directly). Suppression is therefore enforced by the SAME
  `Samen.Delivery.Chokepoint.suppressed?/2` net every other send family uses —
  Outreach does not invent its own suppression list.

  ## Reply-detection pause — reads the EXISTING T74 Mailbox seam, never a third
  inbound path

  `Samen.Sequences.ReplyCheck` is a host-injectable check
  (`config :samen_core, Samen.Sequences.ReplyCheck, module: ...`), mirroring the
  Chokepoint's own `suppression_module` seam: unwired degrades to `{:ok, false}`
  (never auto-pauses — the honest "no reply source configured" absence), a
  RAISING check fails CLOSED on the SEND side (the step is retried later rather
  than fired without knowing whether a reply already arrived).
  `Samen.Sequences.MailboxReplyCheck` is the real, production implementation:
  it queries the ALREADY-SHIPPED `Samen.Mailbox.MailMessage`-shaped resource
  (`subject_key == "crm.person" and subject_id == person_id and direction ==
  :inbound`, org-pinned) — the SAME generic object-ref anchor the T74 Mailbox
  sync engine writes. No new inbound ingestion mechanism is introduced anywhere
  in this scope.

  ## Fail-honest scheduling (mirrors Reminder/Escalation, ADR-039 §5.9)

  `Enrollment` carries an AshOban `:sequence_step_due` trigger (queue
  `:automation_timers`, `scheduler_cron("* * * * *")`, explicit — mirrors
  `Automation.Reminder`'s `:reminder_due` trigger line for line). A step that
  cannot actually be sent (`{:error, :adapter_unconfigured}` — no ESP wired,
  ADR-014 §3) is recorded `StepSend.status == :blocked` and the enrollment's
  `current_step` is NEVER advanced past it — a blocked step retries, it is never
  silently treated as delivered. A suppressed recipient's `StepSend.status ==
  :suppressed` and the enrollment transitions to `:stopped` PERMANENTLY (spec
  I2 done-criterion 3).
  """

  # ---------------------------------------------------------------------------
  # Sequence — tenant-authored multi-step outreach definition. Org-scoped. No PII
  # (steps are tenant-authored template config, not subject data).
  # ---------------------------------------------------------------------------
  defmacro define_sequence(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Outreach.Sequence — a tenant-defined multi-step outreach sequence (spec
        §I2). `steps` is a bounded, ordered jsonb list of
        `%{"delay_hours" => non_neg_integer, "subject" => string, "body" =>
        string}` maps — tenant-authored template config, not PII (same posture as
        `Marketing.Template`). Validated + normalized at write time by
        `Samen.Sequences.ValidateSteps`. Org-scoped. Admin-gated writes.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_sequence")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            default: :draft,
            constraints: [one_of: [:draft, :active, :archived]]
          )

          attribute(:steps, {:array, :map}, public?: true, default: [])
        end

        changes do
          change(Samen.Sequences.ValidateSteps)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Enrollment — one CRM contact's membership in a Sequence. Org-scoped. No PII
  # (`person_id` is an opaque reference, never the identity data itself).
  # ---------------------------------------------------------------------------
  defmacro define_enrollment(module, otp_app, domain, repo, abbrev, sequence_mod, step_send_mod) do
    resolved = Macro.expand(module, __CALLER__)
    scheduler_mod = Module.concat(resolved, SequenceStepDueScheduler)
    worker_mod = Module.concat(resolved, SequenceStepDueWorker)

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Outreach.Enrollment — one CRM contact's membership in a `Sequence` (spec
        §I2). `person_id` is a plain opaque uuid (no FK — mirrors
        `Samen.Scopes.Mailbox.MailMessage.company_id`'s "the scope mounts
        independently" posture). `current_step` points at the step NOT YET
        confirmed sent; it only advances on a genuine `{:ok, receipt}` from the
        C2 chokepoint (`Samen.Sequences.resolve_outcome/3`) — a blocked/failed
        step never fakes progress. `status :stopped` is PERMANENT (suppression);
        `status :paused` with `paused_reason :replied` is the reply-detection
        pause (spec I2 done-criterion 2).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshOban],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_enrollment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:person_id, :uuid, public?: true, allow_nil?: false)

          # T75 fix round MED-5: `:blocked` is a VISIBLE, honest status — a step
          # that could not be sent because no ESP adapter is configured
          # (ADR-014 §3 `:adapter_unconfigured`) surfaces here, not as
          # indistinguishable-from-healthy `:active`. `:blocked` is STILL
          # due-scan-eligible (the AshOban `where` below includes it) so it
          # self-recovers the instant an operator wires an adapter — no manual
          # "unblock" action needed; a successful send's `resolve_outcome/3`
          # unconditionally sets `:active`/`:completed` regardless of the prior
          # status.
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :paused, :completed, :stopped, :blocked]]
          )

          attribute(:current_step, :integer, public?: true, default: 0, allow_nil?: false)
          attribute(:next_send_at, :utc_datetime, public?: true)

          attribute(:paused_reason, :atom,
            public?: true,
            constraints: [one_of: [:replied, :suppressed, :manual]]
          )

          attribute(:enrolled_at, :utc_datetime, public?: true)
          attribute(:completed_at, :utc_datetime, public?: true)

          # T75 fix round MED-4: the reply-detection cutoff. Distinct from
          # `enrolled_at` (a permanent fact, never updated): `:resume` bumps
          # THIS to "now" so a reply that correctly paused the enrollment does
          # not immediately re-pause it on the very next scan after resume —
          # only a NEW reply (after the resume) does. `Samen.Sequences.handle_due/3`
          # reads THIS field, never `enrolled_at`, for the reply check.
          attribute(:reply_cutoff_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :sequence, unquote(sequence_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:sequence]})
        end

        actions do
          defaults([:read, :destroy])

          # Tenant-facing enroll. Computes the initial current_step/status/
          # next_send_at from the Sequence's own steps (Samen.Sequences.initial_state/1)
          # — a sequence with zero steps enrolls straight to :completed (honest: there
          # was nothing to send).
          create :enroll do
            accept([:org_id, :sequence_id, :person_id])

            change(fn changeset, _ctx ->
              sequence_id = Ash.Changeset.get_attribute(changeset, :sequence_id)
              org_id = Ash.Changeset.get_attribute(changeset, :org_id)

              case Samen.Sequences.fetch(unquote(sequence_mod), sequence_id, org_id) do
                {:ok, sequence} ->
                  state = Samen.Sequences.initial_state(sequence)

                  changeset
                  |> Ash.Changeset.change_attribute(:status, state.status)
                  |> Ash.Changeset.change_attribute(:current_step, state.current_step)
                  |> Ash.Changeset.change_attribute(:next_send_at, state.next_send_at)
                  |> Ash.Changeset.change_attribute(:enrolled_at, state.enrolled_at)
                  |> Ash.Changeset.change_attribute(:completed_at, state.completed_at)
                  |> Ash.Changeset.change_attribute(:reply_cutoff_at, state.reply_cutoff_at)

                {:error, _reason} ->
                  Ash.Changeset.add_error(changeset,
                    field: :sequence_id,
                    message: "sequence not found for this org — enrollment refused"
                  )
              end
            end)
          end

          update :pause do
            accept([:paused_reason])
            require_atomic?(false)

            change(set_attribute(:status, :paused))
            change(set_attribute(:next_send_at, nil))

            change(fn changeset, _ctx ->
              case Ash.Changeset.get_argument_or_attribute(changeset, :paused_reason) do
                nil -> Ash.Changeset.force_change_attribute(changeset, :paused_reason, :manual)
                _ -> changeset
              end
            end)
          end

          update :resume do
            accept([])
            require_atomic?(false)
            change(set_attribute(:status, :active))
            change(set_attribute(:paused_reason, nil))

            # T75 fix round MED-4: bump BOTH next_send_at (retry immediately)
            # AND reply_cutoff_at (to "now") — without the latter, the SAME
            # stale reply that (correctly) paused this enrollment would
            # re-pause it on the very next scan, making :resume a permanent
            # no-op for a reply-paused enrollment.
            change(fn changeset, _ctx ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              changeset
              |> Ash.Changeset.force_change_attribute(:next_send_at, now)
              |> Ash.Changeset.force_change_attribute(:reply_cutoff_at, now)
            end)
          end

          update :stop do
            accept([:paused_reason])
            require_atomic?(false)
            change(set_attribute(:status, :stopped))
            change(set_attribute(:next_send_at, nil))
          end

          # Internal cross-org system read used ONLY by the AshOban
          # :sequence_step_due scheduler (bypass-authorized below).
          read :due_scan do
            pagination(keyset?: true, required?: false)
          end

          # System maintenance action driven by the :sequence_step_due AshOban
          # trigger — reply-check, then either pauses on reply or queues the due
          # step's StepSend + enqueues Samen.Sequences.SendWorker.
          update :advance_due do
            accept([])
            require_atomic?(false)

            change(fn changeset, _ctx ->
              id = Ash.Changeset.get_data(changeset, :id)
              enrollment = Samen.Sequences.reload(changeset.resource, id)

              changeset
              |> Ash.Changeset.filter({:status, [in: [:active, :blocked]]})
              |> Ash.Changeset.after_action(fn _changeset, result ->
                if enrollment do
                  Samen.Sequences.handle_due(enrollment, unquote(sequence_mod), unquote(step_send_mod))
                end

                {:ok, result}
              end)
            end)
          end

          # Internal-only state setter — the ONE write path
          # `Samen.Sequences.transition/2` uses for every automated transition
          # (reply-pause, retry-backoff, delivered/suppressed/blocked outcomes).
          # Never tenant-writable (bypass-only policy below).
          update :system_advance do
            accept([:status, :paused_reason, :current_step, :next_send_at, :completed_at])
            require_atomic?(false)
          end
        end

        oban do
          triggers do
            trigger :sequence_step_due do
              action(:advance_due)
              queue(:automation_timers)
              scheduler_cron("* * * * *")
              scheduler_module_name(unquote(scheduler_mod))
              worker_module_name(unquote(worker_mod))
              read_action(:due_scan)
              worker_read_action(:due_scan)
              stream_with(:full_read)
              actor_persister(:none)
              max_attempts(3)

              # T75 fix round MED-5: `:blocked` is ALSO due-scan-eligible (not
              # just `:active`) — an enrollment made honestly `:blocked` by a
              # missing ESP adapter still gets re-considered on its watchdog/
              # retry cadence, so it self-recovers the instant one is wired.
              where(
                expr(
                  ^ref(:status) in [:active, :blocked] and not is_nil(^ref(:next_send_at)) and
                    ^ref(:next_send_at) <= now()
                )
              )
            end
          end
        end

        policies do
          bypass action([:advance_due, :due_scan, :system_advance]) do
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action([:enroll, :pause, :resume, :stop]) do
            forbid_unless(Samen.Policy.OrgScope)
            authorize_if(always())
          end

          policy action_type(:destroy) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # StepSend — one step's send outcome (queued/delivered/blocked/suppressed/
  # failed/skipped). Org-scoped, system-written only. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_step_send(module, otp_app, domain, repo, abbrev, enrollment_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Outreach.StepSend — the honest per-step send outcome (spec §I2). Created
        `:queued` by `Enrollment`'s `:advance_due` action, resolved by
        `Samen.Sequences.SendWorker` to exactly one of `:delivered | :blocked |
        :suppressed | :failed | :skipped` — NEVER `:delivered` unless a
        configured C2 adapter genuinely returned `{:ok, _}` (ADR-014 §3
        Invariant D1, carried here unchanged). Org-scoped; system-written only
        (tenant plane can READ its own send history, never write it directly).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_step_send")
          repo(unquote(repo))
        end

        attributes do
          attribute(:step_index, :integer, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            default: :queued,
            constraints: [one_of: [:queued, :delivered, :blocked, :suppressed, :failed, :skipped]]
          )

          attribute(:queued_at, :utc_datetime, public?: true)
          attribute(:sent_at, :utc_datetime, public?: true)
          attribute(:provider_message_id, :string, public?: true)
          attribute(:custom, :map, public?: true)
        end

        relationships do
          belongs_to :enrollment, unquote(enrollment_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:enrollment]})
        end

        actions do
          defaults([:read, :destroy])

          # Internal-only: created by Enrollment's :advance_due action.
          create :queue do
            accept([:org_id, :enrollment_id, :step_index])
            change(set_attribute(:status, :queued))
            change(fn changeset, _ctx -> Ash.Changeset.force_change_attribute(changeset, :queued_at, DateTime.utc_now() |> DateTime.truncate(:second)) end)
          end

          # Internal-only: the ONE write path Samen.Sequences.SendWorker uses to
          # resolve a queued StepSend to its final honest outcome.
          update :mark do
            accept([:status, :sent_at, :provider_message_id, :custom])
            require_atomic?(false)
          end

          # T75 fix round MED-2/MED-5: `Samen.Sequences.find_or_create_step_send/2`
          # reuses (never duplicates) the SAME row across retry/watchdog cycles
          # for one `(enrollment_id, step_index)` — this is the REUSE half of
          # that reuse-or-create: reset an existing `:queued | :blocked | :failed`
          # row back to `:queued` rather than inserting a new one every cycle
          # (the fix for the unbounded-StepSend-row-flood finding).
          update :requeue do
            accept([])
            require_atomic?(false)
            change(set_attribute(:status, :queued))

            change(fn changeset, _ctx ->
              Ash.Changeset.force_change_attribute(
                changeset,
                :queued_at,
                DateTime.utc_now() |> DateTime.truncate(:second)
              )
            end)
          end
        end

        policies do
          bypass action([:queue, :mark, :requeue]) do
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type(:destroy) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
