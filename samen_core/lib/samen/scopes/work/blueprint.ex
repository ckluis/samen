defmodule Samen.Scopes.Work.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Work** scope (F1; ADR-041 §3 — the canonical
  Work-scope Task, binding design).

  Objects: `project · task` (self-referential — the Subtask tree is `task.parent_id`,
  not a third resource, ADR-041 §3.1).

  ## PII map — EMPTY (INV-1)

  Neither `Project` nor `Task` carries a vault-routed field. `Task.title`/`.body`/
  `.custom` are freeform user content (Activity parity, ADR-041 §3.3/§10) —
  **default-deny-CDC-excluded, not vaulted**. `owner_id`, `subject_key`/`subject_id`,
  `priority`, and every id/timestamp are structurally non-PII. See
  `Samen.Scopes.Work` moduledoc for the full PII posture table and the T43 c3
  empty-PII-map declaration test.

  ## `owner_id` is a plain uuid, not a `belongs_to` (documented deviation from the
  ADR table's shorthand)

  ADR-041 §3.2 lists `owner (owner_id)` as `belongs_to User, :uuid`. The Work scope
  blueprint is mounted independently of any host's Identity namespace (exactly like
  `Samen.Automation.Run.owner_id`, `samen_core/lib/samen/scopes/automation/blueprint.ex:97`,
  the direct precedent this mirrors) — requiring a `user_mod` at mount time would
  couple the Work scope's mount macro to a specific Identity module shape, which
  ADR-041 §4.1 explicitly rejects for the CRM case and the same reasoning applies
  here: a plain `:uuid` `owner_id` (no relationship, no same-org FK check) carries
  the same semantic (an assignable user id) without a hard cross-scope coupling. A
  host that wants FK-level integrity may add a `SameOrgFk`-style check itself,
  scoped to its own Identity mount — out of the Work scope's substrate concern.

  ## Subtask tree — cycle refusal (§3.4)

  `Task.parent_id` is a genuine self-referential `belongs_to`. Every create/update
  changing `parent_id` runs `Samen.Scopes.Work.CycleGuard` (a node cannot become its
  own transitive ancestor; the walk is depth-bounded).

  ## Soft-delete + cascade (ADR-040 §5.9, ADR-041 §3.5)

  Both resources are `archivable: true`. Project → Task is **not** a cascade (a task
  outlives its project's archival, ADR-040 §5.4 default). Task → Subtask **is** a
  declared cascade (`archive_related([:subtasks])`) — archiving a parent task
  archives its subtree at the same instant. Restore matches the instant too:
  `Samen.Scopes.Work.CascadeRestore` (scoped to `:restore` only) is the restore-side
  counterpart ash_archival does not ship.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage), matching every other
  Samen scope.
  """

  # ---------------------------------------------------------------------------
  # Project — a container noun (name, status, owner). Org-scoped. No PII.
  # Archivable. Project archival does NOT cascade to Task (a task outlives its
  # project's archival — ADR-041 §3.5, ADR-040 §5.4 default no-cascade).
  # ---------------------------------------------------------------------------
  defmacro define_project(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Work.Project — a container noun for grouping Tasks (F1). Org-scoped. No PII
        — `name` is authored content (parity with every other authored-label field
        in the foundry, e.g. `Support.Sla.name`), not subject identity.

        Archivable (ADR-040 §5.9). Archiving a Project does NOT cascade to its Tasks
        (ADR-041 §3.5) — a task outlives its project's archival.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_project")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :on_hold, :completed, :cancelled]]
          )
          # Plain uuid — see blueprint moduledoc "`owner_id` is a plain uuid" note.
          attribute(:owner_id, :uuid, public?: true)
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Task — the canonical Work item (ADR-041 §3.2, field-for-field). Self-referential
  # (parent_id — the Subtask tree, cycle-refused). Org-scoped. No PII. Archivable,
  # cascading to its own subtree.
  # ---------------------------------------------------------------------------
  defmacro define_task(module, otp_app, domain, repo, abbrev, project_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Work.Task — the canonical Work-scope task (ADR-041 §3, absorbed field-for-field
        onto what was CRM Activity — the migration is T97's, this resource is T43's
        creation of the destination only, NO CRM contact).

        `kind` mirrors Activity's exact `type` enum; `status` is a PLAIN atom enum
        (Activity's set + `:in_progress`) — **not** an `ash_state_machine`, per
        ADR-041 §4.3 (Task absorbs already-terminal logged kinds; a bulk migration
        inserts terminal-state rows directly). `priority` uses `Samen.Type.Priority`
        (ADR-036). `subject_key`/`subject_id` is the generic CRM-agnostic object-ref
        anchor (`Samen.Web.ObjectRef`, `samen:<key>:<uuid>`) — never a CRM FK
        (ADR-041 §4.1, the T43/T97 partition enabler). `parent_id` is the
        self-referential Subtask tree (cycle-refused, `Samen.Scopes.Work.CycleGuard`).
        `project_id` links to an optional `Project`.

        Archivable (ADR-040 §5.9); archiving a Task cascades to its Subtask subtree
        (`archive_related([:subtasks])`, ADR-041 §3.5).

        No PII: `title`/`body`/`custom` are freeform user content, unvaulted
        (Activity parity, default-deny-CDC-excluded, never plaintext-mirrored).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_task")
          repo(unquote(repo))
        end

        attributes do
          attribute(:kind, :atom,
            public?: true,
            default: :task,
            constraints: [one_of: [:task, :call, :email, :meeting, :note]]
          )
          attribute(:title, :string, public?: true)
          attribute(:body, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :pending,
            constraints: [one_of: [:pending, :in_progress, :completed, :cancelled]]
          )
          attribute(:priority, Samen.Type.Priority, public?: true, default: :normal)
          attribute(:due_at, :utc_datetime, public?: true)
          attribute(:completed_at, :utc_datetime, public?: true)
          # The generic object-ref anchor (ADR-041 §4.1) — CRM-agnostic by construction.
          # `subject_id` resolves ONLY within the org via `Samen.Web.ObjectRef.resolve/3`
          # (the SameOrgFk-equivalent boundary for a non-belongs_to anchor, ADR-041 §6.1).
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)
          attribute(:custom, :map, public?: true)
          # Plain uuid — see blueprint moduledoc "`owner_id` is a plain uuid" note.
          attribute(:owner_id, :uuid, public?: true)
        end

        relationships do
          belongs_to :parent, __MODULE__ do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          belongs_to :project, unquote(project_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          has_many :subtasks, __MODULE__ do
            public?(true)
            destination_attribute(:parent_id)
          end
        end

        # ADR-041 §3.4: a legal N-level tree is accepted; a cycle is refused.
        # SameOrgFk covers the two genuine belongs_to FKs (parent/project); the
        # generic subject_key/subject_id anchor is NOT a belongs_to and is instead
        # enforced org-scoped at the ObjectRef resolve boundary (ADR-041 §6.1) — not
        # re-implemented here (there is no CRM contact in this scope).
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:parent, :project]})
          change(Samen.Scopes.Work.CycleGuard)
          # Restore-side cascade counterpart to archive_related([:subtasks]) below —
          # ash_archival ships no restore-cascade primitive (ADR-041 §3.5). Self-guards
          # on the action NAME (see CascadeRestore moduledoc) — `:on` alone cannot
          # discriminate :restore from the plain :update (both type :update).
          change(Samen.Scopes.Work.CascadeRestore)
        end

        archive do
          archive_related([:subtasks])
          # System-level structural cascade following an already-authorized parent
          # archive — mirrors CascadeRestore's own `authorize?: false` posture (the
          # actor scope does not automatically thread into ash_archival's internal
          # cascade bulk_destroy; the parent action was already authorized).
          archive_related_authorize?(false)
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
