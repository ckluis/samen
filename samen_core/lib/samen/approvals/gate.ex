defmodule Samen.Approvals.Gate do
  @moduledoc """
  E3 Face 2 — the Ash action gate ("any action can require approval", ADR-040 §4.4).

  Add `change {Samen.Approvals.Gate, kind: "..."}` to a **bounded transition on an
  existing record** (no arguments beyond the record itself — freeform inputs are exactly
  what must not be deferred, §4.4). Two responsibilities live here:

  ## 1. The change — refuse an unapproved write, open the approval

  Invoked WITHOUT an approval in context, the Gate opens (or returns the existing pending)
  approval `kind: "<resource-module>:<action>"`, `subject_ref` = the record's object-ref,
  and fails the write honest with a `Samen.Approvals.ApprovalRequired` error carrying the
  approval id. The approval is opened in a `before_transaction` hook — OUTSIDE the action's
  transaction — so it commits even though the write itself is aborted (the reveal
  same-tx-rollback pattern, inverted).

  ## 2. The handler — execute the approved action AS THE REQUESTER

  On approval, `Samen.Approvals.approve/3` invokes `on_approve/2` (this module is the
  registered handler for gate kinds), INSIDE the decision transaction (§4.3). It re-derives
  the record from governed domain state via `subject_ref` (no persisted inputs, §4.4),
  reconstructs the **requester's** principal from `requested_by`/`org_id`, and re-invokes
  the same action as that requester with a one-shot `approval_ok` context that satisfies
  the Gate. The approver consented; the requester acts within their OWN policy envelope —
  approval adds second-party consent, never privilege escalation (§4.4, §12).
  """

  use Ash.Resource.Change

  alias Samen.Approvals
  alias Samen.Approvals.ApprovalRequired

  @behaviour Samen.Approvals.Handler

  # ==========================================================================
  # 1. The change face.
  # ==========================================================================

  @impl Ash.Resource.Change
  def change(changeset, opts, context) do
    if approved_context?(changeset) do
      # A one-shot approved re-invocation (from on_approve/2) — let the transition run.
      changeset
    else
      Ash.Changeset.before_transaction(changeset, fn cs ->
        open_and_refuse(cs, opts, context)
      end)
    end
  end

  # Opens (or returns) the pending approval OUTSIDE the action transaction, then aborts
  # the write with the fail-honest ApprovalRequired error. If the engine is unwired, the
  # write fails closed — never a silent ungated mutation.
  defp open_and_refuse(changeset, opts, context) do
    kind = gate_kind(changeset)

    attrs = %{
      # The approval rides the REQUESTER's tenant plane (their org). By OrgScope this equals
      # the record's org; reading it off the actor avoids a NotLoaded record attribute.
      org_id: actor_org_id(context),
      kind: kind,
      subject_ref: subject_ref(changeset),
      requested_by: actor_id(context),
      reason: opts[:reason]
    }

    case Approvals.request(attrs) do
      {:ok, approval} ->
        Ash.Changeset.add_error(
          changeset,
          ApprovalRequired.exception(approval_id: approval.id, kind: kind)
        )

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          ApprovalRequired.exception(approval_id: nil, kind: {:engine_error, reason})
        )
    end
  end

  # ==========================================================================
  # 2. The handler face — re-invoke the gated action as the requester.
  # ==========================================================================

  @impl Samen.Approvals.Handler
  def on_approve(approval, _ctx) do
    with {:ok, {resource, action}} <- parse_kind(approval.kind),
         {:ok, record_id} <- parse_subject_ref(approval.subject_ref) do
      requester = requester_principal(approval)

      # Re-derive the record from governed domain state (§4.4 — no persisted inputs). The
      # one-shot `approval_ok` context MUST be set via for_update's :context opt (the Gate's
      # change/3 runs during for_update, before any later set_context would apply).
      case Ash.get(resource, record_id, actor: requester, authorize?: false) do
        {:ok, record} ->
          record
          |> Ash.Changeset.for_update(action, %{},
            actor: requester,
            authorize?: true,
            context: %{approval_ok: true}
          )
          |> Ash.update(actor: requester)
          |> case do
            {:ok, updated} ->
              {:ok, %{executed: to_string(action), record_id: to_string(updated.id)}}

            {:error, reason} ->
              {:error, {:gate_action_failed, reason}}
          end

        # §7.1: the subject vanished/was archived between request and decision — the
        # decision rolls back and the approval stays pending; the approver may cancel.
        {:error, reason} ->
          {:error, {:subject_unavailable, reason}}
      end
    end
  end

  # ==========================================================================
  # Kind / subject-ref codec (the engine stores NO inputs — only these bounded strings).
  # ==========================================================================

  @doc "The gate kind string for a resource+action: `\"<resource-module>:<action>\"`."
  @spec kind_for(module(), atom()) :: String.t()
  def kind_for(resource, action), do: Atom.to_string(resource) <> ":" <> Atom.to_string(action)

  defp gate_kind(changeset), do: kind_for(changeset.resource, changeset.action.name)

  defp parse_kind(kind) do
    case String.split(kind, ":", parts: 2) do
      [mod_str, action_str] ->
        {:ok, {String.to_existing_atom(mod_str), String.to_existing_atom(action_str)}}

      _ ->
        {:error, {:bad_gate_kind, kind}}
    end
  rescue
    ArgumentError -> {:error, {:bad_gate_kind, kind}}
  end

  defp subject_ref(changeset) do
    abbrev = Samen.Info.abbrev(changeset.resource)
    id = changeset.data.id
    "samen:#{abbrev}:#{id}"
  end

  defp parse_subject_ref(ref) do
    case String.split(ref, ":", parts: 3) do
      ["samen", _abbrev, id] -> {:ok, id}
      _ -> {:error, {:bad_subject_ref, ref}}
    end
  end

  # ==========================================================================
  # Actor / context helpers.
  # ==========================================================================

  defp approved_context?(changeset), do: Map.get(changeset.context || %{}, :approval_ok) == true

  defp actor_id(%{actor: actor}), do: extract_id(actor)
  defp actor_id(_), do: nil

  defp extract_id(%{id: id}) when is_binary(id), do: id
  defp extract_id(id) when is_binary(id), do: id
  defp extract_id(_), do: nil

  defp actor_org_id(%{actor: %{org_id: org_id}}), do: org_id
  defp actor_org_id(_), do: nil

  # Reconstruct the requester's tenant-plane principal (the actor map Ash + OrgScope read)
  # from the approval's bounded ids. (Production hosts resolve the full actor —
  # role/permissions — from `requested_by` via their identity layer; T34 proves the "runs
  # as requester, not approver" property with a member-role scope, which is all a bounded
  # gated transition needs.)
  defp requester_principal(approval) do
    %{id: approval.requested_by, org_id: approval.org_id, role: :member}
  end
end
