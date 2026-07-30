defmodule SamenCore.Support.ApprovalsFixture.Approval do
  @moduledoc """
  T34 E3 fixture — the `Approval` state-bearing resource (ADR-040 §4.1), materialized in
  `samen_core`'s TestRepo ONLY (the per-host primitives materialization is T35's sweep,
  §4.7). Mirrors the ADR's `define_approval` blueprint shape; the production engine
  (`Samen.Approvals`) reaches it through the host-wired `:approval_resource` seam.

    * **AshStateMachine lifecycle**: `pending → approved | rejected | expired | cancelled`
      (all decided states terminal). Illegal transitions are refused by the machine
      (`NoMatchingTransition`) — the exactly-once guard (§4.3).
    * **`org_id allow_nil? true`** — the documented CoreAttributes exception (the
      Identity.Org precedent): non-NULL = tenant-plane approval (OrgScope-policed);
      NULL = plane-global governance approval (reveal), structurally hidden from tenant
      actors by OrgScope's fail-closed filter.
    * **Distinct-party DB CHECK** `apv_distinct_party` (`apv_decided_by IS NULL OR
      apv_decided_by <> apv_requested_by`) — the `rvg_distinct_party` twin — lives in the
      migration; the NULL-org exception is inherent (the CHECK keys on the parties, never
      the org).
    * **No persisted inputs** (§4.4): the row carries only `{org_id, kind, subject_ref,
      requested_by, decided_by, reason, state, deadline_at, timestamps}` — never action
      inputs. `reason` is PiiReasonScan-gated at write (see `Samen.Approvals`).
    * **Expiry**: one AshOban trigger (`:expire_scan`, explicit `scheduler_cron`, ID-only
      args, `actor_persister :none`) transitions past-deadline pending rows to `expired`.

  Deliberately NOT in `:ash_domains` (kept out of the CI verifier/catalog sweeps, like the
  automation/notification fixtures).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.ApprovalsFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban],
    abbrev: "apv"

  postgres do
    table("apv_approval")
    repo(SamenCore.TestRepo)
  end

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:approve, from: :pending, to: :approved)
      transition(:reject, from: :pending, to: :rejected)
      transition(:cancel, from: :pending, to: :cancelled)
      transition(:expire, from: :pending, to: :expired)
    end
  end

  attributes do
    # org_id declared HERE (allow_nil? true) so CoreAttributes' maybe_add skips it — the
    # documented Identity.Org exception (§4.1). AbbrevStorage still prefixes it apv_org_id.
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)

    attribute(:kind, :string, public?: true, allow_nil?: false)
    attribute(:subject_ref, :string, public?: true, allow_nil?: false)
    attribute(:requested_by, :string, public?: true, allow_nil?: false)
    attribute(:decided_by, :string, public?: true)
    # PiiReasonScan-gated at write; freeform, NOT vault-routed (the approver must read it).
    attribute(:reason, :string, public?: true)
    attribute(:deadline_at, :utc_datetime_usec, public?: true)
    attribute(:requested_at, :utc_datetime_usec, public?: true)
    attribute(:decided_at, :utc_datetime_usec, public?: true)

    # Pre-declare the AshStateMachine state attribute so `Samen.Transformers.AbbrevStorage`
    # prefixes its physical column `apv_state` (the ADR-037 §5.8 C2 self-qualifying-storage
    # duty — same mechanism ash_archival's `archived_at` uses); AshStateMachine's own
    # attribute-injection then adopts this existing one instead of adding an unprefixed
    # `state`. `writable? false` — transitions go only through the machine's actions.
    attribute(:state, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [one_of: [:pending, :approved, :rejected, :expired, :cancelled]]
    )
  end

  actions do
    defaults([:read])

    create :open do
      accept([:org_id, :kind, :subject_ref, :requested_by, :reason, :deadline_at, :requested_at])
    end

    update :approve do
      accept([:decided_by])
      require_atomic?(false)
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:approved))
    end

    update :reject do
      accept([:decided_by])
      require_atomic?(false)
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:rejected))
    end

    update :cancel do
      accept([])
      require_atomic?(false)
      change(transition_state(:cancelled))
    end

    # System read/update driven by the :expire_scan AshOban trigger (bypass-authorized).
    read :scan_expired do
      pagination(keyset?: true, required?: false)
    end

    update :expire do
      accept([])
      require_atomic?(false)
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:expired))
      # AshOban drives :expire directly on the resource (not via the engine API), so the
      # governance audit (§4.3 approval_expired) is attached here, inside the worker tx.
      change(after_action(&audit_expired/3))
    end
  end

  oban do
    triggers do
      trigger :expire_scan do
        action(:expire)
        queue(:automation_timers)
        scheduler_cron("* * * * *")
        scheduler_module_name(SamenCore.Support.ApprovalsFixture.Approval.ExpireScanScheduler)
        worker_module_name(SamenCore.Support.ApprovalsFixture.Approval.ExpireScanWorker)
        read_action(:scan_expired)
        worker_read_action(:scan_expired)
        stream_with(:full_read)
        # ID-only args, no actor persisted (the §5.9 sink rule).
        actor_persister(:none)
        max_attempts(3)

        where(
          expr(
            ^ref(:state) == :pending and not is_nil(^ref(:deadline_at)) and
              ^ref(:deadline_at) <= now()
          )
        )
      end
    end
  end

  defp audit_expired(_changeset, record, _context) do
    Samen.AuditChain.Writer.write(SamenCore.TestRepo, %{
      org_id: record.org_id || Samen.AuditChain.global_org(),
      event_type: "approval_expired",
      subject_id: record.subject_ref,
      actor_id: "system:expiry_scan",
      correlation_id: to_string(record.id),
      detail: "event=approval_expired kind=#{record.kind}",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })

    {:ok, record}
  end

  policies do
    # The expiry scan runs the system :expire/:scan_expired actions with no actor.
    bypass action([:expire, :scan_expired]) do
      authorize_if(always())
    end

    # Tenant-surface reads are org-scoped (NULL-org governance rows fall out for tenant
    # actors by OrgScope's fail-closed filter — the cross-org red test covers both dirs).
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Decide actions: the approver must be at least :admin (§4.5 tenant default). The
    # engine's own writes pass authorize?: false (a trusted kernel API, the Grants
    # precedent); this policy governs any direct tenant-surface decide.
    policy action([:approve, :reject]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end

end

defmodule SamenCore.Support.ApprovalsFixture.Document do
  @moduledoc """
  T34 E3 fixture — a governed reference client with TWO Gate-guarded action types
  (`:publish`, `:lock`; done-criterion 4) plus plain actions used by the Face-1
  handler-registry proofs. Carries a 🔒 vault field (`pii_secret`) so the INV-1
  no-persisted-inputs proof is non-vacuous: the approval row for a publish decision holds
  NO plaintext/`vt_*` token — only the object-ref `subject_ref`.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.ApprovalsFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apd"

  postgres do
    table("apd_document")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      default: :draft,
      constraints: [one_of: [:draft, :published, :locked]]
    )

    attribute(:published_by, :uuid, public?: true)
    attribute(:locked_by, :uuid, public?: true)
    attribute(:note, :string, public?: true)
  end

  pii do
    vault(:pii_secret)
    pii_attribute(:secret, :string, vault: :pii_secret)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:org_id, :title, :secret])
    end

    # Gate-guarded transition #1 — bounded, no arguments beyond the record itself (§4.4).
    update :publish do
      accept([])
      require_atomic?(false)
      change({Samen.Approvals.Gate, kind: :gated})
      change(set_attribute(:status, :published))
      change(&stamp_publisher/2)
    end

    # Gate-guarded transition #2 (a DIFFERENT gated action type).
    update :lock do
      accept([])
      require_atomic?(false)
      change({Samen.Approvals.Gate, kind: :gated})
      change(set_attribute(:status, :locked))
      change(&stamp_locker/2)
    end

    # Plain action a Face-1 handler re-derives + drives inside the decision transaction.
    update :mark_note do
      accept([:note])
      require_atomic?(false)
    end
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

  # Record the ACTING actor (the requester after approval) — the "runs as requester, not
  # approver" proof (§4.4): published_by/locked_by must equal requested_by, never decided_by.
  defp stamp_publisher(changeset, context) do
    Ash.Changeset.change_attribute(changeset, :published_by, actor_id(context))
  end

  defp stamp_locker(changeset, context) do
    Ash.Changeset.change_attribute(changeset, :locked_by, actor_id(context))
  end

  defp actor_id(%{actor: %{id: id}}), do: id
  defp actor_id(_), do: nil
end

defmodule SamenCore.Support.ApprovalsFixture.NoteHandler do
  @moduledoc """
  A Face-1 (handler-registry) client (ADR-040 §4.4). Proves a NON-Ash-gate kernel client:
  its `on_approve/2` re-derives the Document from `subject_ref` (no persisted inputs) and
  drives the plain `:mark_note` action INSIDE the decision transaction. The reveal grant
  becomes exactly this kind of client in T35.
  """
  @behaviour Samen.Approvals.Handler

  alias SamenCore.Support.ApprovalsFixture.Document

  @impl true
  def on_approve(approval, _ctx) do
    id = subject_id(approval.subject_ref)

    with {:ok, doc} <- Ash.get(Document, id, authorize?: false) do
      doc
      |> Ash.Changeset.for_update(:mark_note, %{note: "approved"}, authorize?: false)
      |> Ash.update()
      |> case do
        {:ok, _} -> {:ok, %{noted: true}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp subject_id(ref) do
    ["samen", _abbrev, id] = String.split(ref, ":", parts: 3)
    id
  end
end

defmodule SamenCore.Support.ApprovalsFixture.BoomHandler do
  @moduledoc """
  A Face-1 handler that performs a governed DB write and THEN fails — the same-tx rollback
  proof (the reveal guarantee T35 relies on, §4.3/§4.4): the Document write and the
  approval transition + audit must ALL roll back together, leaving the approval `pending`.
  """
  @behaviour Samen.Approvals.Handler

  alias SamenCore.Support.ApprovalsFixture.Document

  @impl true
  def on_approve(approval, _ctx) do
    id = subject_id(approval.subject_ref)

    {:ok, doc} = Ash.get(Document, id, authorize?: false)

    {:ok, _} =
      doc
      |> Ash.Changeset.for_update(:mark_note, %{note: "boom-wrote-this"}, authorize?: false)
      |> Ash.update()

    # ...then fail. The whole decision transaction must roll back the note write above.
    {:error, :boom}
  end

  defp subject_id(ref) do
    ["samen", _abbrev, id] = String.split(ref, ":", parts: 3)
    id
  end
end

defmodule SamenCore.Support.ApprovalsFixture do
  @moduledoc """
  Kernel fixture domain for the T34 E3 approve/reject engine. Materializes the `Approval`
  (`apv`) state machine + a `Document` (`apd`) Gate-client in `samen_core`'s TestRepo.

  Deliberately NOT in `:ash_domains` (kept out of the CI verifier/catalog sweeps, like the
  automation/notification fixtures); `pii_apd_secret` is allow-listed for
  `vault_declared_parity` in `config/test.exs`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.ApprovalsFixture.Approval)
    resource(SamenCore.Support.ApprovalsFixture.Document)
  end
end
