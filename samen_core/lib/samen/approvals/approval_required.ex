defmodule Samen.Approvals.ApprovalRequired do
  @moduledoc """
  The fail-honest error a Gate-guarded action raises when it is invoked without an
  approval in context (ADR-040 §4.4, Face 2). Carries the `approval_id` of the pending
  approval the Gate opened (or returned), so a caller can route the requester to the
  decision surface. Class `:forbidden` — a gated write is refused, not malformed.
  """
  use Splode.Error, fields: [:approval_id, :kind], class: :forbidden

  def message(%{approval_id: id, kind: kind}) do
    "approval_required: a distinct-party approval (#{inspect(kind)}) is pending as #{id}"
  end
end
