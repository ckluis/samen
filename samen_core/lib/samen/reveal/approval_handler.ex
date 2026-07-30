defmodule Samen.Reveal.ApprovalHandler do
  @moduledoc """
  T35 §4.7 — the Face-1 approval handler registered for kind `"pii_reveal"`
  (`Samen.Approvals.Registry`; ADR-040 §4.4, the handler-registry shape
  `SamenCore.Support.ApprovalsFixture.NoteHandler` proved in T34).

  Runs **inside** the approvals engine's decision transaction
  (`Samen.Approvals.approve/3`, §4.3): re-derives the governed `RevealRequest` from
  `approval.subject_ref` (no persisted inputs, §4.4 — the engine never sees the request's
  fields, only the object-ref string) and executes the EXISTING
  `Samen.Reveal.Grants.do_approve/4` Multi body — grant insert + `granted` audit +
  same-tx auto-revoke enqueue. Because that Multi now runs inside the engine's own
  transaction (both riding the SAME configured repo, the host-wired seam), the reveal
  same-tx guarantee (§4.3 / `reveal_grant_same_tx_test.exs`) is preserved when reveal
  becomes an engine client: a handler error (or a DB CHECK violation inside `do_approve`)
  rolls back the grant insert, the audit, the Oban enqueue, AND the approval's own
  `pending -> approved` transition together.
  """

  @behaviour Samen.Approvals.Handler

  alias Samen.Reveal.{Grants, RevealRequest}

  @subject_ref_prefix "samen:reveal.request:"

  @doc "The `subject_ref` string for a `RevealRequest` (ADR-040 §4.7)."
  @spec subject_ref(RevealRequest.t()) :: String.t()
  def subject_ref(%RevealRequest{id: id}), do: @subject_ref_prefix <> id

  @impl true
  def on_approve(approval, ctx) do
    with {:ok, request_id} <- parse_subject_ref(approval.subject_ref),
         {:ok, req} <- fetch_request(ctx.repo, request_id) do
      opts =
        ctx.opts
        |> Map.new()
        |> Map.put(:repo, ctx.repo)

      case Grants.do_approve(req, ctx.actor, opts, ctx.repo) do
        {:ok, grant} -> {:ok, %{grant_id: to_string(grant.id)}}
        {:error, _reason} = err -> err
      end
    end
  end

  defp parse_subject_ref(@subject_ref_prefix <> request_id), do: {:ok, request_id}
  defp parse_subject_ref(other), do: {:error, {:bad_subject_ref, other}}

  defp fetch_request(repo, request_id) do
    case repo.get(RevealRequest, request_id) do
      %RevealRequest{} = req -> {:ok, req}
      nil -> {:error, :reveal_request_not_found}
    end
  end
end
