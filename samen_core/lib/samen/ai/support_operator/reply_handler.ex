defmodule Samen.AI.SupportOperator.ReplyHandler do
  @moduledoc """
  The E3 Face-1 approval handler (ADR-040 §4.4) registered for kind `"ai_support_reply"`
  (ADR-043 §6.3, T70) — the **single, human-gated path** from an AI support draft to an
  actual send.

  Runs INSIDE the approvals engine's decision transaction (`Samen.Approvals.approve/3`,
  §4.3), invoked ONLY when a DISTINCT human approves (the engine refuses `decided_by ==
  requested_by` at both the policy layer and the `apv_distinct_party` DB CHECK, so the AI
  service principal that requested the draft can never be the approver). It:

    1. re-derives the `Samen.AI.SupportReplyDraft` from `approval.subject_ref` (no persisted
       inputs, §4.4 — the approval row never held the reply body);
    2. builds a **token-only** `Samen.Delivery.Message` (the recipient's email is revealed
       from the vault at `deliver/2` time, never carried here) and sends it through
       `Samen.Delivery.Chokepoint.send/2` — THE single delivery chokepoint (ADR-038 §4.3),
       within the draft's OWN org;
    3. marks the draft `:sent` on success.

  ## Fail-honest send (ADR-014/024/026)

  If delivery is unconfigured (`{:blocked, :adapter_unconfigured}` outside `:test`), the
  chokepoint returns `{:error, :adapter_unconfigured}` — NEVER a fake `{:ok, _}`. This
  handler propagates that as `{:error, {:delivery_failed, reason}}`, which rolls the WHOLE
  decision transaction back: the approval stays `pending`, the draft stays `:draft`, and
  nothing was sent. A configured provider genuinely dispatched; a suppressed recipient is
  refused at the chokepoint like any other send.

  ## Options threaded from `approve/3` (`ctx.opts`)

    * `:delivery_env` — the delivery env (`:test` enables the honest `LocalSink`; default
      `:prod`, which is fail-honest when no adapter is configured);
    * `:fallback_adapter` / `:fallback_config` — the caller's legacy per-org adapter, used
      when `Samen.Delivery.ProviderSelection` resolves nothing for the org (the
      `Samen.Delivery.Chokepoint.send/2` seam).
  """

  @behaviour Samen.Approvals.Handler

  alias Samen.Delivery.{Chokepoint, Message}

  @impl true
  def on_approve(approval, ctx) do
    with {:ok, draft_id} <- parse_subject_ref(approval.subject_ref),
         {:ok, draft} <- fetch_draft(draft_id) do
      message = %Message{
        send_id: to_string(draft.id),
        org_id: draft.org_id,
        to_subscriber_id: to_string(draft.to_subscriber_id),
        template_id: nil
      }

      case Chokepoint.send(message, send_opts(ctx.opts)) do
        {:ok, receipt} ->
          case mark_sent(draft) do
            {:ok, _sent} -> {:ok, %{sent: true, send_id: to_string(draft.id), sink: Map.get(receipt, :sink, false)}}
            {:error, reason} -> {:error, {:mark_sent_failed, reason}}
          end

        {:error, reason} ->
          # Fail-honest: propagate the block so the WHOLE decision rolls back — approval
          # stays pending, draft stays :draft, nothing sent. NEVER swallowed into an :ok.
          {:error, {:delivery_failed, reason}}
      end
    end
  end

  @impl true
  def on_reject(approval, _ctx) do
    with {:ok, draft_id} <- parse_subject_ref(approval.subject_ref),
         {:ok, draft} <- fetch_draft(draft_id) do
      case discard(draft) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # A missing/garbled draft on reject is not a reason to block the rejection.
      _ -> :ok
    end
  end

  # --- send / draft plumbing ---------------------------------------------------------------

  defp send_opts(opts) do
    [env: Keyword.get(opts, :delivery_env, :prod)] ++
      Keyword.take(opts, [:fallback_adapter, :fallback_config])
  end

  # `org_id` is a select-default-false core column; select it so the token-only Message the
  # send carries the draft's real org (never an `%Ash.NotLoaded{}`).
  defp fetch_draft(draft_id), do: Samen.AI.SupportOperator.load_draft(draft_id)

  defp mark_sent(draft) do
    draft
    |> Ash.Changeset.for_update(:mark_sent, %{}, authorize?: false)
    |> Ash.update()
  end

  defp discard(draft) do
    draft
    |> Ash.Changeset.for_update(:discard, %{}, authorize?: false)
    |> Ash.update()
  end

  defp parse_subject_ref(ref) do
    case String.split(ref, ":", parts: 3) do
      ["samen", _abbrev, id] when byte_size(id) > 0 -> {:ok, id}
      _ -> {:error, {:bad_subject_ref, ref}}
    end
  end
end
