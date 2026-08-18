defmodule Samen.Web.CRM.SequencesReads do
  @moduledoc """
  The framework read/write layer for the tenant-plane CRM **Sequences** surface
  (`/crm/sequences`, spec §I2 CRM sequences actually send, T75). It SURFACES the
  EXISTING Outreach scope (`Samen.Scopes.Outreach` — `Sequence`/`Enrollment`/`StepSend`,
  materialized per host) in a tenant UI; it re-implements NONE of the send/enroll/due-scan
  mechanism (that all lives in `Samen.Sequences` + the blueprint's own actions).

  ## Host-agnostic resource derivation (the Mailbox/Work bridge idiom)

  The Outreach scope mounts under the SAME host root as CRM (a sibling `Outreach` domain),
  with NO FK into CRM — `Enrollment.person_id` is a plain opaque uuid (the exact
  `Samen.Scopes.Mailbox.MailMessage.company_id` posture). This module derives the three
  resource modules from the CRM `mount`'s own namespace root, exactly as
  `Samen.Web.CRM.Reads.mailbox_message_resource/1` derives the Mailbox resource — no CRM
  LiveView, reads, or route names a host module. A host that has NOT mounted the Outreach
  scope gets `nil` here and an HONESTLY EMPTY surface (never a fabricated sequence/enrollment).

  ## Org-scope (every read narrows to the actor's org)

  Every read runs through Ash with `scope: scope`, so `Samen.Policy.OrgScope` (the resources'
  own read policy) narrows to the actor's org BY CONSTRUCTION — a tenant sees only its own
  sequences/enrollments/sends. Proven refutably by the cross-org red-path in
  `crm_sequences_test.exs` (another org's enrollment is NOT visible; the same org IS — the
  positive control) + sabotage patch 167 (dropping `scope:` for `authorize?: false` flips it).

  ## No PII on this surface (stated, and proven)

  NONE of the three Outreach resources carry a vaulted (🔒) attribute — there is no `pii_`
  column anywhere on the scope (see the mount migration's INV-1 note). `Enrollment.person_id`
  is an OPAQUE uuid, never identity data; `Sequence.steps` is tenant-AUTHORED template config
  (not subject data); `StepSend` carries only bounded ids/enums/timestamps. This surface
  therefore renders the person id directly (a short, non-secret chip — the SAME posture the
  CRM dashboard's activity leaderboard renders `Task.owner_id`) and NEVER calls
  `Samen.Api.PiiResolution`/`Samen.Vault.reveal/3` — there is no vault field on this path to
  resolve. Verified refutably in `crm_sequences_test.exs` (no `vt_*` token ever reaches the
  DOM; the surface reads no `pii_` column).

  ## Honest send state (never a fabricated "delivered")

  Sends route through the SAME `Samen.Delivery.Chokepoint` (C2) every send family uses; a
  keyless host (no ESP adapter) records the step `StepSend.status == :blocked` and NEVER
  advances the enrollment past it (`Samen.Sequences.resolve_outcome/3`, Invariant D1). This
  surface renders that honest status verbatim — a `:queued | :blocked | :failed | :suppressed`
  step is NEVER labelled "Delivered"/"Sent" (pinned by the honesty test + sabotage patch 168).
  `sends_configured?/1` reads the delivery provider seam (`ProviderSelection`) so the surface
  can say, honestly and up front, when no sender is wired — the SAME fail-honest posture the
  Mailbox settings surface uses for its "not configured" state.
  """

  alias Samen.Web.Mount

  # A3 read-bounding: every read on this surface carries an explicit hard cap.
  @limit 200

  # ---------------------------------------------------------------------------
  # Host-agnostic Outreach resource derivation (the Mailbox/Work bridge idiom)
  # ---------------------------------------------------------------------------

  @doc "Derive the host's `Outreach.Sequence` module from a CRM `mount`, or `nil` when unmounted."
  @spec sequence_resource(Mount.t()) :: module() | nil
  def sequence_resource(mount), do: outreach_resource(mount, "Sequence")

  @doc "Derive the host's `Outreach.Enrollment` module from a CRM `mount`, or `nil` when unmounted."
  @spec enrollment_resource(Mount.t()) :: module() | nil
  def enrollment_resource(mount), do: outreach_resource(mount, "Enrollment")

  @doc "Derive the host's `Outreach.StepSend` module from a CRM `mount`, or `nil` when unmounted."
  @spec step_send_resource(Mount.t()) :: module() | nil
  def step_send_resource(mount), do: outreach_resource(mount, "StepSend")

  defp outreach_resource(%Mount{namespace: ns}, name) do
    root = ns |> Module.split() |> Enum.drop(-1)

    Enum.find_value(["Outreach", "OutreachScope"], fn seg ->
      mod = Module.concat(root ++ [seg, name])
      if live_resource?(mod), do: mod
    end)
  end

  defp outreach_resource(_mount, _name), do: nil

  defp live_resource?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :spark_is, 0) and
      Ash.Resource.Info.resource?(mod)
  rescue
    _ -> false
  end

  @doc "Whether this host has mounted the Outreach scope at all (drives the honest empty state)."
  @spec scope_mounted?(Mount.t()) :: boolean()
  def scope_mounted?(mount), do: not is_nil(enrollment_resource(mount))

  # ---------------------------------------------------------------------------
  # Reads — org-scoped by construction (Ash `scope: scope` ⇒ OrgScope narrows)
  # ---------------------------------------------------------------------------

  @doc """
  This org's outreach sequences (newest first), org-scoped + bounded. `[]` when the
  Outreach scope is not mounted — the honest absence, never a fabricated sequence.
  """
  def sequences(mount, scope) do
    case sequence_resource(mount) do
      nil ->
        []

      resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected([:name, :status, :steps])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(@limit)
        |> Ash.read!(scope: scope)
    end
  rescue
    _ -> []
  end

  @doc """
  This org's enrollments (newest first), org-scoped + bounded. `[]` when the Outreach
  scope is not mounted. NO PII: `person_id` is an opaque uuid (see the moduledoc).
  """
  def enrollments(mount, scope) do
    case enrollment_resource(mount) do
      nil ->
        []

      resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected([
          :person_id,
          :status,
          :current_step,
          :sequence_id,
          :next_send_at,
          :paused_reason,
          :enrolled_at
        ])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(@limit)
        |> Ash.read!(scope: scope)
    end
  rescue
    _ -> []
  end

  @doc """
  A `%{enrollment_id => [step_send]}` map for this org's step sends (org-scoped, bounded).
  `%{}` when the scope is not mounted. Each `StepSend` carries the HONEST outcome status
  (`:queued | :delivered | :blocked | :suppressed | :failed | :skipped`) the surface
  renders verbatim — never re-derived into a fabricated "sent".
  """
  def step_sends_by_enrollment(mount, scope) do
    case step_send_resource(mount) do
      nil ->
        %{}

      resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected([:step_index, :status, :sent_at, :enrollment_id, :queued_at])
        |> Ash.Query.sort(step_index: :asc)
        |> Ash.Query.limit(@limit)
        |> Ash.read!(scope: scope)
        |> Enum.group_by(& &1.enrollment_id)
    end
  rescue
    _ -> %{}
  end

  @doc """
  Enroll a contact (`person_id`) into a `sequence_id` via the EXISTING blueprint `:enroll`
  action (`Samen.Scopes.Outreach.Blueprint` — computes initial step/status from the
  sequence's own steps; a zero-step sequence enrolls straight to `:completed`, honest). The
  write rides the action's OWN org-scope policy (`Samen.Policy.OrgScope` + a same-org
  sequence check inside the action itself — a cross-org `sequence_id` is REFUSED). This
  module invents no new action. `{:ok, enrollment}` or `{:error, reason}`.
  """
  def enroll(mount, scope, sequence_id, person_id) do
    with resource when not is_nil(resource) <- enrollment_resource(mount),
         org_id when is_binary(org_id) <- scope_org_id(scope) do
      resource
      |> Ash.Changeset.for_create(
        :enroll,
        %{org_id: org_id, sequence_id: sequence_id, person_id: person_id},
        scope: scope
      )
      |> Ash.create()
    else
      nil -> {:error, :scope_not_mounted}
      _ -> {:error, :no_org}
    end
  rescue
    e -> {:error, e}
  end

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp scope_org_id(_), do: nil

  @doc """
  Whether a real delivery provider is wired for `org_id` — the fail-honest predicate the
  surface reads (never assumed) to decide between its "sends are live" and its honest
  "no sender is configured" states. Reads the SAME `Samen.Delivery.ProviderSelection` seam
  the C2 chokepoint resolves through: a `{module, config}` pair means a sender exists; `nil`
  means none is wired (a step that comes due is recorded `:blocked`, never faked delivered).
  """
  @spec sends_configured?(String.t() | nil) :: boolean()
  def sends_configured?(org_id) do
    match?({_module, _config}, Samen.Delivery.ProviderSelection.resolve!(org_id))
  rescue
    _ -> false
  end
end
