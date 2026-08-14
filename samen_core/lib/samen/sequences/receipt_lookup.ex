defmodule Samen.Sequences.ReceiptLookup do
  @moduledoc """
  The `Samen.Delivery.Deliverability` `:receipt_lookup` implementation for
  sequence sends (T75 fix round MED-3) — the SAME registration seam
  `Samen.Delivery.MarketingReceiptLookup` uses, mirrored exactly, so a bounce/
  complaint on a sequence step writes the SAME `Samen.Delivery.Suppression`
  (`dlv_suppression`) row every other send family gets. NO second suppression
  store is invented.

  ## The gap this closes

  `StepSend` carries no `subscriber_id` (unlike `Marketing.Send`) — the actual
  recipient identity lives one hop away, on `Enrollment.person_id`. Before this
  module existed, a hard bounce/complaint on a sequence step's
  `provider_message_id` had NO registered lookup anywhere (only
  `MarketingReceiptLookup` was ever wired), so `Samen.Delivery.Deliverability`
  never matched it, no `dlv_suppression` row was ever written for a bounced
  sequence recipient, and — because sequences send exclusively through the
  SAME `Samen.Delivery.Chokepoint.suppressed?/2` net (never a parallel
  suppression list) — a bounced/complained address kept receiving further
  sequence steps forever. Only a MANUALLY-suppressed `person_id` was ever
  protected.

  ## Usage

      config :samen_core, Samen.Delivery.Deliverability,
        receipt_lookup: Samen.Sequences.ReceiptLookup.build(MyApp.Outreach.StepSend, MyApp.Outreach.Enrollment)

  A host running BOTH Marketing and Outreach composes its own combinator
  (`Samen.Delivery.Deliverability` accepts any arity-1 function):

      receipt_lookup: fn pmi ->
        case Samen.Delivery.MarketingReceiptLookup.build(Send).(pmi) do
          :not_found -> Samen.Sequences.ReceiptLookup.build(StepSend, Enrollment).(pmi)
          found -> found
        end
      end

  ## Org-pinned by construction

  The returned receipt's `org_id`/`subscriber_id` come from the MATCHED
  `StepSend`/`Enrollment` rows themselves (never from the webhook payload) —
  `Samen.Delivery.Suppression.suppress/2` then writes `{org_id, subscriber_id}`
  exactly as resolved here, so the resulting suppression row is scoped to the
  SAME org the bounced step actually belongs to. A DIFFERENT org's enrollment
  of the identically-shaped `person_id` is untouched (the `dlv_suppression`
  table's own compound key, `Samen.Delivery.Chokepoint.suppressed?/2`'s
  existing org-pinned check — nothing new to pin here beyond that established
  contract).
  """

  require Ash.Query

  alias Samen.Sequences

  @doc """
  Build a receipt-lookup function backed by `step_send_module` (carrying
  `provider_message_id`/`org_id`/`enrollment_id`) and `enrollment_module`
  (carrying `person_id` — the actual recipient identity `Suppression.suppress/2`
  keys on).
  """
  @spec build(module(), module()) :: (String.t() -> {:ok, map()} | :not_found)
  def build(step_send_module, enrollment_module)
      when is_atom(step_send_module) and is_atom(enrollment_module) do
    fn provider_message_id -> lookup(step_send_module, enrollment_module, provider_message_id) end
  end

  defp lookup(_step_send_module, _enrollment_module, nil), do: :not_found

  defp lookup(step_send_module, enrollment_module, provider_message_id) do
    with {:ok, send_row} <- fetch_send(step_send_module, provider_message_id),
         {:ok, enrollment} <- Sequences.fetch_by_id(enrollment_module, send_row.enrollment_id) do
      {:ok, %{send_id: send_row.id, org_id: send_row.org_id, subscriber_id: enrollment.person_id}}
    else
      _ -> :not_found
    end
  rescue
    # A host whose StepSend schema doesn't (yet) carry provider_message_id, or
    # any other read hiccup, degrades to "couldn't match" — never a crash of
    # the webhook worker (mirrors MarketingReceiptLookup's own posture; an
    # unmatched event goes to the DLQ via Samen.Delivery.Deliverability, it
    # never takes the pipeline down).
    _ -> :not_found
  end

  defp fetch_send(step_send_module, provider_message_id) do
    step_send_module
    |> Ash.Query.filter(provider_message_id == ^provider_message_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.limit(1)
    # authz-scope: webhook-ingest receipt lookup keyed on the unique provider_message_id
    # (<=1 row); org_id is read FROM the matched send row, never from the request
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
