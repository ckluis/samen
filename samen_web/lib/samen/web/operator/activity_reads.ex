defmodule Samen.Web.Operator.ActivityReads do
  @moduledoc """
  Operator activity/audit read layer (R3/T115; `_orch/ux/dogfood-report.md` R4 —
  P4 job-test 4, "what changed in org X in the last 24h?"). Answers it by merging
  a governance tier + a business-history tier for ONE tenant org, bounded to a
  time window.

  ## Governance tier (`Samen.AuditEvent`, `aud_event` — T2.2)

  The append-only event log EVERY host carries (unlike the T4.3 `aud_chain`
  hash-chain, which is not yet deployed on every host — this reader
  deliberately does not depend on it, so it works everywhere `aud_event`
  does). `aud_event` has NO `org_id` column — every writer smuggles org
  context through EITHER `subject_id` OR `correlation_id`, by convention, and
  the convention is NOT uniform across event types. Reads therefore use THREE
  separately-scoped sub-queries, each keyed on the field its writer(s)
  provably set to a real `org_id` — never a blanket filter over either field:

    1. **Impersonation family** (`subject_id == org_id`) — `impersonation_write`
       (T38's P7-F1-mandated per-write row, `Samen.Audit.ImpersonationEmit`)
       and `impersonation` (session open/close bookends,
       `Samen.Impersonation.Sessions.emit_event/3`) — both provably set
       `subject_id` to the target org.
    2. **The "system" bucket** (`event_type == "system" AND correlation_id ==
       org_id`) — every LIVE "system"-typed writer that sets `correlation_id`
       at all sets it to the mutated record's OWN `org_id`, read directly off
       that record (never derived/guessed): `primitives.notification.sent`
       (`Samen.Scopes.Primitives.Audit.notification_sent/3`),
       `primitives.file.uploaded` / `primitives.file.promoted`
       (`.../primitives/audit.ex`), `support.ticket.breached`
       (`Samen.Scopes.Support.Audit.ticket_breached/3`),
       `automation.workflow.<kill|rearm>` (`Samen.Automation.Health.audit_switch/4`),
       `automation.workflow.rate_tripped` (`Samen.Automation.Breaker`),
       `marketing.send.blocked` (`Samen.Scopes.Marketing.SendWorker`). A
       "system" row whose writer never sets `correlation_id` (the dead
       `identity.auth.*` family, `identity.role_changed`, `identity.api_key`)
       has `correlation_id = nil`, which never matches `== org_id` — excluded,
       fails closed, never mis-attributed.
    3. **The approval family** (`approval_requested | approval_approved |
       approval_rejected | approval_cancelled | approval_self_decide_refused`,
       `Samen.Approvals`) — `correlation_id` here is the Approval row's OWN
       id, NOT an org id (INDIRECT). Org-scoping resolves it by first querying
       the host's configured Approval resource
       (`Application.get_env(:samen_core, Samen.Approvals)[:approval_resource]`
       — the SAME host-wiring seam `Samen.Approvals.wiring/1` reads) for the
       set of approval ids belonging to `org_id`, THEN filtering `aud_event`
       to `correlation_id in that_set`. The org-filter is therefore pushed
       into the id-set construction itself — an approval id belonging to a
       DIFFERENT org can never appear in `org_id`'s set, so this cannot bleed
       cross-org even under a busy multi-tenant window. Unwired (no host
       config) or an org with zero approvals ⇒ `[]`, immediately, no query —
       fail-honest, never a partial join.

  **Explicitly NOT included** (no safe org-linkage exists on `aud_event`
  alone for these — see the T115 fix-round disposition, `work/summary.md`):
  `operator_suspension` (`correlation_id` is the OPERATOR id, not an org — no
  org signal on this tier at all); `break_glass` (`correlation_id` defaults to
  a fresh random UUID, unrelated to org); `grant_lifecycle` / `erasure`
  (neither `subject_id` nor `correlation_id` maps to an org on ANY call site —
  the real org, when the caller even supplies one, lands ONLY on the
  `aud_chain` sibling row via `AuditChain.Writer.write/2`'s `:org_id` key,
  which `do_write/2` never copies onto the `aud_event` row itself);
  `record_archived` / `record_restored` (`correlation_id` is unset/nil;
  resolving org requires parsing an arbitrary resource-module token out of
  `detail` and issuing a per-row lookback query against that resource,
  including archived rows — real, unverified complexity this fix round does
  not take on). Every one of these would need either a universal `aud_chain`
  migration (the org lives there) or a bespoke indirect join — filed as
  follow-up, not silently dropped.

  Every governance-tier field is a bounded id/enum/token/timestamp by
  construction (no writer above ever puts an attribute VALUE in `aud_event` —
  only object-refs/ids); `detail` is `Samen.PiiReasonScan`-gated at write
  time. There is nothing to mask on this tier — the same "token-blind by
  construction" posture `Samen.Web.Operator.WebhookDlqLive` documents for its
  own tier.

  ## Business-history tier (T119's `<Resource>.Version` rows, ADR-040 §6)

  The per-attribute diff for any resource a host has opted into `versioned:`.
  Enumerated generically via `Samen.Catalog` + `Samen.Info.versioned?/1`
  (framework-first: a host with zero `versioned` resources sees this half of
  the feed honestly empty; a host that adopts T119 later gets it merged in at
  0 additional LOC here).

  ## Masking (INV-1) — NEVER resolved, only ever token/class markers

  A `Version` row's `changes` diff can carry a vault-routed (🔒) attribute's
  `vt_*` token (proven never plaintext by T119's own INV-1 gate,
  `versioned_change_log_test.exs`). This reader renders EXACTLY what T119
  stores: any key that is vault-routed on its source resource
  (`Samen.Pii.Info.pii_attributes/1`) is passed through
  `Samen.Type.VaultField.cast_stored/2` — a STATIC cast with no grant/vault
  argument at all, so it is structurally incapable of resolving to plaintext —
  never through `Samen.Api.PiiResolution` (which COULD, under a live reveal
  grant, hand back cleartext; that side channel is deliberately never opened
  here, per CLAUDE.md: "this UI must not 'helpfully' resolve a diff's vaulted
  value ... it renders exactly what the change-log row stores"). Every other
  key renders as its stored value untouched (proving the token is the vault
  type's doing, not blanket redaction, mirroring `versioned_change_log_test.exs`).

  ## Org-scoped, cross-tenant drill-down (INV-2)

  Like `DeliverabilityReads`/`Automation.Health`, this is an operator reaching
  ANY tenant org by id (not the operator's own book) — every sub-query above
  is EXPLICITLY org-scoped (never a blanket `authorize?: true` policy read,
  which `Samen.Policy.OrgScope` — trusting the *actor's* own org — cannot
  express for a cross-tenant drill-down) and `authorize?: false`. No
  cross-org bleed: every row returned carries the SAME org_id passed in,
  never a second org's data — proven per sub-query (impersonation family,
  "system" bucket, approval family) in `activity_masking_test.exs`, each with
  its own two-org no-bleed proof and a fails-closed edge (nil/unmatched
  correlation_id, an unrelated event type, an unresolvable approval id).
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Samen.AuditEvent
  alias Samen.Web.Mount

  @default_window_hours 24
  @max_window_hours 24 * 30
  @governance_limit 200
  @version_limit_per_resource 100
  @feed_limit 250

  # The ONLY `aud_event` event types where `subject_id` is provably `org_id` —
  # see the moduledoc. Never widen this set without re-verifying the writer's
  # `subject_id` convention for the new type.
  @impersonation_event_types ~w(impersonation_write impersonation)

  # `event_type == "system"` rows whose LIVE writers set `correlation_id` to
  # the mutated record's own `org_id` directly — see the moduledoc's
  # enumeration. A single bucket (not a per-sub-type list) because `event_type`
  # itself does not distinguish "webhook registered" from "workflow tripped"
  # — only `detail`'s prefix does, and every writer in this bucket shares the
  # SAME `correlation_id = org_id` convention.
  @system_bucket_event_type "system"

  # The Approval engine's decision-lifecycle events (`Samen.Approvals`,
  # ADR-040 §4) — `correlation_id` is the Approval row's OWN id (INDIRECT org
  # resolution, see the moduledoc).
  @approval_event_types ~w(approval_requested approval_approved approval_rejected approval_cancelled approval_self_decide_refused)

  @doc """
  Chronological activity feed for ONE tenant org: governance-tier `aud_event`
  rows (including T38's impersonation-write rows) merged with any T119
  `versioned` resource's Version-row diffs, bounded to `opts[:window_hours]`
  (default #{@default_window_hours}h, clamped to [1, #{@max_window_hours}]h),
  newest first, capped at #{@feed_limit} rows. Any read error on either tier
  degrades that tier to `[]` — fail-honest, never a crash, never a partial page
  presented as complete for the other tier.

  Returns `%{items:, window_hours:, cutoff:}`. Each item:
  `%{id:, tier: :governance | :history, occurred_at:, action:, actor_id:,
  object_ref:, impersonation?:, session_id:, detail:, changes:}` — `changes` is
  `nil` on governance-tier items (there is no diff to show; the object-ref IS
  the payload) and a `[{key, value}]` list (masked per the moduledoc) on
  history-tier items.
  """
  @spec activity(Mount.t(), String.t(), keyword()) :: map()
  def activity(mount, org_id, opts \\ [])

  def activity(_mount, nil, _opts), do: %{items: [], window_hours: @default_window_hours, cutoff: nil}

  def activity(%Mount{} = mount, org_id, opts) do
    window_hours = clamp_window(Keyword.get(opts, :window_hours, @default_window_hours))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -window_hours * 3600, :second)

    items =
      (governance_items(mount.repo, org_id, cutoff) ++ history_items(mount, org_id, cutoff))
      |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
      |> Enum.take(@feed_limit)

    %{items: items, window_hours: window_hours, cutoff: cutoff}
  end

  defp clamp_window(hours) when is_integer(hours), do: hours |> max(1) |> min(@max_window_hours)

  defp clamp_window(hours) when is_binary(hours) do
    case Integer.parse(hours) do
      {n, _} -> clamp_window(n)
      :error -> @default_window_hours
    end
  end

  defp clamp_window(_), do: @default_window_hours

  # ---------------------------------------------------------------------------
  # Governance tier — THREE independently org-scoped sub-queries over
  # aud_event (INV-2: each keyed on the field its writer(s) provably set to a
  # real org_id — see the moduledoc; never a blanket filter over either
  # subject_id or correlation_id). Each sub-query rescues its OWN failure so
  # one tier's error never blanks the others (fail-honest, partial-degrade).
  # ---------------------------------------------------------------------------

  defp governance_items(repo, org_id, cutoff) when is_atom(repo) and not is_nil(repo) do
    impersonation_rows(repo, org_id, cutoff) ++
      system_bucket_rows(repo, org_id, cutoff) ++
      approval_rows(repo, org_id, cutoff)
  end

  defp governance_items(_repo, _org_id, _cutoff), do: []

  # -- 1. Impersonation family: subject_id == org_id (T38 P7-F1) ---------------

  defp impersonation_rows(repo, org_id, cutoff) do
    AuditEvent
    |> where(
      [e],
      e.subject_id == ^org_id and e.event_type in ^@impersonation_event_types and e.occurred_at >= ^cutoff
    )
    |> order_by([e], desc: e.occurred_at)
    |> limit(^@governance_limit)
    |> repo.all()
    |> Enum.map(&governance_item(&1, true))
  rescue
    _ -> []
  end

  # -- 2. The "system" bucket: event_type == "system" AND correlation_id == org_id (DIRECT) --

  defp system_bucket_rows(repo, org_id, cutoff) do
    AuditEvent
    |> where(
      [e],
      e.event_type == ^@system_bucket_event_type and e.correlation_id == ^org_id and e.occurred_at >= ^cutoff
    )
    |> order_by([e], desc: e.occurred_at)
    |> limit(^@governance_limit)
    |> repo.all()
    |> Enum.map(&governance_item(&1, false))
  rescue
    _ -> []
  end

  # -- 3. Approval family: correlation_id is an Approval id (INDIRECT) ---------
  # Resolve the org's OWN approval ids FIRST (a single scoped query), then
  # filter aud_event to `correlation_id in that_set` — the org filter is
  # therefore baked into the id-set construction itself, so an approval
  # belonging to a DIFFERENT org structurally cannot appear here, even under a
  # busy multi-tenant window (no post-hoc/in-memory filtering after a
  # cross-org fetch).

  defp approval_rows(repo, org_id, cutoff) do
    case approval_ids_for_org(org_id) do
      [] ->
        []

      approval_ids ->
        AuditEvent
        |> where(
          [e],
          e.event_type in ^@approval_event_types and e.correlation_id in ^approval_ids and
            e.occurred_at >= ^cutoff
        )
        |> order_by([e], desc: e.occurred_at)
        |> limit(^@governance_limit)
        |> repo.all()
        |> Enum.map(&governance_item(&1, false))
    end
  rescue
    _ -> []
  end

  # The SAME host-wiring seam `Samen.Approvals.wiring/1` reads
  # (`config :samen_core, Samen.Approvals, approval_resource: ...`). Unwired
  # (no host has adopted the Approvals engine, e.g. samen_web's own test
  # host today) or an org with zero approvals ⇒ `[]` immediately, no query —
  # fail-honest, never a partial/guessed join.
  defp approval_ids_for_org(org_id) do
    case Application.get_env(:samen_core, Samen.Approvals, [])[:approval_resource] do
      nil ->
        []

      resource ->
        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
    end
  rescue
    _ -> []
  end

  defp governance_item(%AuditEvent{} = e, impersonation?) do
    %{
      id: "aud-#{e.id}",
      tier: :governance,
      occurred_at: e.occurred_at,
      action: action_label(e),
      actor_id: e.actor_id,
      object_ref: object_ref_label(e),
      # ONLY the impersonation family renders the "acting as tenant" block —
      # see `@impersonation_event_types`. `correlation_id` is the
      # impersonation session id and `subject_id` is the tenant org acted
      # upon (`Samen.Audit.ImpersonationEmit` / `Sessions.emit_event/3`) —
      # carried through explicitly so the row renders "operator X acting as
      # tenant Y, session Z", never folded into a generic actor field
      # (done-criterion 2). The "system"/approval buckets render as ordinary
      # attributable rows (actor_id, action, object_ref) — real changes to
      # org X, but not operator-impersonation events.
      impersonation?: impersonation?,
      session_id: if(impersonation?, do: e.correlation_id && to_string(e.correlation_id), else: nil),
      tenant_subject_id: if(impersonation?, do: e.subject_id, else: nil),
      detail: e.detail,
      changes: nil
    }
  end

  # `detail`'s conventions differ PER event-type family (all
  # `Samen.PiiReasonScan`-gated at write time, all token-only) — resolving the
  # friendly "action" label therefore keys on `event_type`, not one generic
  # regex chain, so a family whose `detail` happens to contain a token another
  # family treats specially (e.g. approval rows' `event=<lifecycle>`) is never
  # mis-parsed into a LESS informative label than its own already-descriptive
  # `event_type` (e.g. `"approval_requested"` beats a bare `"requested"`).
  #
  #   * impersonation_write: `event=impersonation_write action=<name>
  #     session=<id> subject=<ref>` — the REAL mutated Ash action (`action=`)
  #     is more informative than the constant event_type.
  #   * impersonation (session bookends): `event=<open|close|expired> reason=…`
  #     — the lifecycle token IS the action.
  #   * "system" bucket: a dotted `<namespace>.<event>.<name> key=value ...`
  #     prefix, no `action=`/`event=` label — the leading token IS the action.
  #   * everything else (approval_*, and any future type): `event_type`
  #     itself is already the descriptive label; detail is rendered
  #     separately, verbatim, and never mined for a "better" label.
  defp action_label(%AuditEvent{event_type: "impersonation_write", detail: detail} = e),
    do: capture(detail, ~r/action=(\S+)/) || e.event_type

  defp action_label(%AuditEvent{event_type: "impersonation", detail: detail} = e),
    do: capture(detail, ~r/event=(\S+)/) || e.event_type

  defp action_label(%AuditEvent{event_type: @system_bucket_event_type, detail: detail} = e),
    do: first_token(detail) || e.event_type

  defp action_label(%AuditEvent{event_type: event_type}), do: event_type

  # `subject=<ref>` only ever appears in an impersonation_write row's detail
  # (`Samen.Audit.ImpersonationEmit`'s object-ref token). Every other family
  # falls back to `subject_id` directly — already the mutated record's own id
  # ("system" bucket) or its object-ref string (approval's `subject_ref`) —
  # never fabricated.
  defp object_ref_label(%AuditEvent{detail: detail, subject_id: subject_id}) do
    capture(detail, ~r/subject=(\S+)/) || subject_id
  end

  defp capture(str, regex) when is_binary(str) do
    case Regex.run(regex, str) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp capture(_str, _regex), do: nil

  defp first_token(detail) when is_binary(detail) do
    case String.split(detail, " ", parts: 2) do
      [token | _] when token != "" -> token
      _ -> nil
    end
  end

  defp first_token(_detail), do: nil

  # ---------------------------------------------------------------------------
  # Business-history tier — T119 Version rows, enumerated generically over every
  # `versioned` resource the host's mounted domain declares.
  # ---------------------------------------------------------------------------

  defp history_items(%Mount{domain: domain}, org_id, cutoff) when not is_nil(domain) do
    domain
    |> Samen.Catalog.resource_modules()
    |> Enum.filter(&Samen.Info.versioned?/1)
    |> Enum.flat_map(&version_rows_for(&1, org_id, cutoff))
  rescue
    _ -> []
  end

  defp history_items(_mount, _org_id, _cutoff), do: []

  defp version_rows_for(resource, org_id, cutoff) do
    version_mod = Module.concat(resource, Version)
    vault_names = vault_field_names(resource)
    abbrev = Samen.Info.abbrev(resource) || "res"

    version_mod
    |> Ash.Query.filter(org_id == ^org_id and version_inserted_at >= ^cutoff)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(@version_limit_per_resource)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&history_item(&1, abbrev, vault_names))
  rescue
    _ -> []
  end

  defp vault_field_names(resource) do
    resource
    |> Samen.Pii.Info.pii_attributes()
    |> Enum.map(&to_string(&1.name))
    |> MapSet.new()
  end

  defp history_item(version_row, abbrev, vault_names) do
    %{
      id: "version-#{version_row.id}",
      tier: :history,
      occurred_at: version_row.version_inserted_at,
      action: to_string(version_row.version_action_type),
      actor_id: nil,
      object_ref: "samen:#{abbrev}:#{version_row.version_source_id}",
      impersonation?: false,
      session_id: nil,
      tenant_subject_id: nil,
      detail: nil,
      changes: mask_changes(version_row.changes, vault_names)
    }
  end

  @doc false
  # Exposed for the masking-mechanism unit test (mirrors
  # `versioned_change_log_test.exs`'s masked-render proof, at the read-layer
  # level). NEVER calls `Samen.Api.PiiResolution` / the vault — `cast_stored/2`
  # takes no grant/actor argument, so this function is structurally incapable
  # of returning plaintext for a vault-routed key.
  @spec mask_changes(map() | nil, MapSet.t()) :: [{String.t(), term()}] | nil
  def mask_changes(nil, _vault_names), do: nil

  def mask_changes(changes, vault_names) when is_map(changes) do
    changes
    |> Enum.map(fn {k, v} ->
      if MapSet.member?(vault_names, k) do
        {k, mask_value(v)}
      else
        {k, v}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp mask_value(v) when is_binary(v) do
    {:ok, masked} = Samen.Type.VaultField.cast_stored(v, [])
    to_string(masked)
  rescue
    _ -> "••••"
  end

  defp mask_value(_v), do: "••••"
end
