defmodule Samen.Audit.ImpersonationWrite do
  @moduledoc """
  The P7-F1 write-granularity audit for operator-under-impersonation mutations
  (ADR-040 §6.6; persona-7 finding **P7-F1**, security · ESCALATE) — as an
  **in-transaction, fail-closed** `Ash.Resource.Change` added to EVERY
  `use Samen.Resource` (via `Samen.Transformers.ImpersonationAudit`).

  ## Why a change, not a notifier

  The first cut used an `Ash.Notifier`, which had two holes a post-commit notifier cannot
  close: (1) bulk actions default `notify?: false` so they escaped it, and (2) it ran
  post-commit and swallowed errors, so a failed audit could be silently lost — the write
  committed WITHOUT its audit. A `Change` runs as a changeset **hook inside the action
  pipeline** (independent of `notify?`) and can abort the write. It is the single
  enforcer — there is no notifier safety net (an earlier interim design added one for
  destroys; it is retired now that the change covers destroys in-transaction, below).

  ## Registered `on: [:create, :update, :destroy]` — load-bearing

  `Samen.Transformers.ImpersonationAudit` registers this change with an explicit
  `on: [:create, :update, :destroy]`. Ash global changes default to **create + update
  only**, so without `:destroy` the hook never fires for destroy actions — that was the
  actual reason bulk_destroy AND atomic single `:destroy`/`:destroy_permanently` escaped
  the audit (not any actor "back-fill"). Registered for `:destroy`, `atomic/3` fires per
  destroyed record with the operator marker on `context.actor`, so **destroys are audited
  in-transaction and fail-closed exactly like create/update**.

  ## The hook, and why it is added in BOTH `change/3` and `atomic/3`

  The audit is emitted from an **`after_action`** hook (atomic-safe — `after_action` is
  excluded from the non-atomic-forcing `dirty_hooks` check in `update.ex`, so normal
  writes stay atomic; no substrate-wide `require_atomic? false`). The hook is added:

    * in **`change/3`** — the non-atomic path (single writes that run changes; stream/
      non-atomic bulk, where `change/3` runs per record); and
    * in **`atomic/3`** — the atomic path. Load-bearing: for an atomic single write
      (default `:destroy`/`:update`) Ash calls `atomic/3` and SKIPS `change/3`, so the
      hook must be added here too. `atomic/3` also makes bulk_update/bulk_destroy usable
      (a change with no `atomic/3` triggers `NoMatchingBulkStrategy`). Adding a non-empty
      `after_action` makes Ash force `return_records?` + run the hook per record for
      atomic bulk too. A `context` flag (`@ctx_flag`) dedups so exactly one hook is added
      even if both callbacks touch a changeset.

  ## The acting actor — read from `context.actor` (the reliable lever)

  The operator is read from the `%Ash.Resource.Change.Context{}` `.actor` field
  (`= opts[:actor]`) — reliable per record for every action type incl. bulk_destroy. The
  changeset's `context.private.actor` (a fallback) can be polluted with the record-origin
  actor on re-reading paths, so `context.actor` is preferred; the marker also travels in
  the scope's SHARED context (`Samen.Scope.context`) as a further fallback.

  ## Scoped to impersonated writes only (zero cost otherwise)

  The hook is added ONLY when the acting actor carries the `:impersonation` marker
  (`%{operator_id, org_id, session_id}`, set solely by `Samen.Impersonation.Scope.build/1`
  — a plain tenant member scope never has it). A non-impersonated write adds no hook and
  bears no cost; ordinary tenant CRUD is never blanket-audited (E7 stays opt-in).

  ## Fail-closed (in the same transaction)

  The audit `aud_event`(+`aud_chain`) is written via `Samen.AuditChain.Writer` on the
  resource's repo **inside the action's transaction**. If it fails, the `after_action`
  hook returns `{:error, _}` — Ash aborts and rolls back, so an impersonated write that
  cannot record its audit does NOT commit.

  ## Coverage

  Covered, in-transaction and fail-closed, for EVERY write path: single-record
  create/update/destroy/archive/restore/destroy_permanently, plus `Ash.bulk_create`,
  `Ash.bulk_update`, AND `Ash.bulk_destroy` (per destroyed record).

  ## The row (INV-2 two-plane, INV-1 value-free)

  A token-only governance `aud_event`, `event_type "impersonation_write"` (disjoint from
  the session-lifecycle `"impersonation"` events — ADR-040 §7.4), naming BOTH identities:
  `actor_id`=operator, `correlation_id`=the impersonation session id, `org_id`/`subject_id`
  =the tenant org, and `detail = "event=impersonation_write action=<name> session=<id>
  subject=samen:<abbrev>:<id>"` — the action + the mutated record's object-ref, and NO
  attribute values (INV-1: the row cannot leak a mutated value or a `vt_*` token).
  """
  use Ash.Resource.Change

  @ctx_flag :samen_impersonation_audited

  # Non-atomic path (single writes running changes; stream / non-atomic bulk per record).
  @impl true
  def change(changeset, _opts, context) do
    case marker(changeset, context) do
      nil -> changeset
      marker -> attach(changeset, marker)
    end
  end

  # Atomic path. Load-bearing: an atomic single write (default :destroy/:update) calls
  # atomic/3 and SKIPS change/3, and a change with no atomic/3 breaks bulk_update/destroy
  # (NoMatchingBulkStrategy). We make no atomic attribute changes — just (conditionally)
  # add the same after_action audit hook and return the changeset.
  @impl true
  def atomic(changeset, _opts, context) do
    case marker(changeset, context) do
      nil -> :ok
      marker -> {:ok, attach(changeset, marker)}
    end
  end

  # Add the after_action audit hook exactly once (dedup via a context flag, since a
  # changeset may pass through both callbacks).
  defp attach(changeset, marker) do
    if Map.get(changeset.context, @ctx_flag) do
      changeset
    else
      changeset
      |> Ash.Changeset.set_context(%{@ctx_flag => true})
      |> Ash.Changeset.after_action(fn cs, result -> audit(cs, result, marker) end)
    end
  end

  # --------------------------------------------------------------------------

  defp audit(changeset, result, marker) do
    case emit(changeset, result, marker) do
      :ok ->
        {:ok, result}

      {:error, reason} ->
        # FAIL-CLOSED: an impersonated write that cannot record its audit must abort.
        # Returning {:error, _} from after_action rolls back the action's transaction —
        # no orphaned (unaudited) mutation, no partial audit row.
        {:error,
         "impersonation_write audit failed (write aborted, fail-closed): " <>
           inspect(reason)}
    end
  end

  defp emit(changeset, result, marker) do
    if Samen.Audit.ImpersonationEmit.fault_injected?() do
      {:error, :audit_fault_injected}
    else
      action = changeset.action && changeset.action.name
      Samen.Audit.ImpersonationEmit.emit(changeset.resource, action, result, marker)
    end
  end

  # Resolve the impersonation marker. Prefer the change `Context.actor` (= opts[:actor],
  # the reliable acting-actor lever), then the scope's SHARED context threaded onto the
  # changeset, then (last) the changeset's own actor. This order matters: the changeset's
  # `context.private.actor` is polluted with the record-origin actor on re-read paths.
  defp marker(changeset, context) do
    if version_resource?(changeset.resource) do
      # Four-tiers-disjoint (ADR-040 §7.4): an E7 `<Resource>.Version` write is created
      # by ash_paper_trail's CreateNewVersion INSIDE the source action's transaction,
      # carrying the SAME actor. Without this guard an impersonated source write would
      # emit a spurious SECOND impersonation_write aud_event for the version row — the
      # source resource's row already attributes the operator. The Version row (E7
      # business-history tier) and the §6.6 governance aud_event stay distinct: exactly
      # one aud_event per impersonated write, never one on the version resource too.
      nil
    else
      marker_from(Map.get(context, :actor)) ||
        changeset_context_marker(changeset) ||
        marker_from(changeset_actor(changeset))
    end
  end

  # ash_paper_trail stamps every generated version module with `resource_version?/0`.
  defp version_resource?(resource) do
    is_atom(resource) and function_exported?(resource, :resource_version?, 0) and
      resource.resource_version?()
  end

  defp marker_from(%{impersonation: %{session_id: session_id} = m}) when is_binary(session_id),
    do: m

  defp marker_from(_), do: nil

  defp changeset_actor(%Ash.Changeset{context: context}) do
    context |> Map.get(:private, %{}) |> Map.get(:actor)
  end

  defp changeset_actor(_), do: nil

  # `%Samen.Scope{}.context` (`%{samen_impersonation: marker}`) is threaded as Ash shared
  # context; depending on the path it lands at the top level of the action context or
  # under a `:shared` key.
  defp changeset_context_marker(%Ash.Changeset{context: context}) do
    case Map.get(context, :samen_impersonation) ||
           get_in(context, [:shared, :samen_impersonation]) do
      %{session_id: session_id} = m when is_binary(session_id) -> m
      _ -> nil
    end
  end

  defp changeset_context_marker(_), do: nil
end
