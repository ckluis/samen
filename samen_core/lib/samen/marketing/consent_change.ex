defmodule Samen.Marketing.ConsentChange do
  @moduledoc """
  An Ash change that appends ONE `Marketing.ConsentEvent` row per consent transition
  on a subscriber create/update — the consent-capture seam (F3 Unit 1), modeled
  line-for-line on `Samen.Billing.SubscriptionMovement` (the `mov` ledger seam) and,
  before it, `Samen.Notifications.StatusChange`.

  Attached by the `Marketing.Subscriber` blueprint as:

      change({Samen.Marketing.ConsentChange, event_resource: Demo.MarketingScope.ConsentEvent})

  ## Semantics

    * Fires on every subscriber create/update, in an `after_action` hook.
    * Classifies the consent transition from the changeset:
      - `:granted`  — the row is `:active` AND `consent_at` is set (an opt-in). On a
        create with a consent timestamp, or an update that (re)sets it / flips status
        back to `:active` with consent on file.
      - `:withdrawn` — the row is `:unsubscribed`, `:bounced`, or `:complained` (an
        opt-out / hard bounce / spam complaint), OR `consent_at` was cleared to nil.
    * Appends ONE `ConsentEvent` row with the derived `event`, the subscriber's
      `source`, the `purpose` (default `:marketing`), an erasure-surviving
      `subject_hash` (the trace-sink pseudonym), and `occurred_at`.
    * A create/update that does NOT change the consent-relevant facts appends NOTHING
      (no duplicate rows for a metadata-only edit).

  ## Suppression HASH survives erasure

  `subject_hash` is derived HERE, at append time, via `Samen.WideEvent.for_subject/1`
  (`HMAC(subject_dek, subject_id)`) — while the subject's key still exists. The
  resulting handle is stored as bytes on the immutable ledger row, which a later
  `Samen.Erasure.shred/2` never touches. So the withdrawn fact + its pseudonym outlive
  the crypto-shred: "do-not-contact" is honored after the PII is unrecoverable. If the
  pseudonym cannot be derived (subject already shredded, KMS hiccup), `subject_hash` is
  left nil — the `event`/`subscriber_id`/`occurred_at` still record the transition.

  ## Best-effort by contract (the A4 emit pattern)

  BEST-EFFORT, exactly like `SubscriptionMovement` / `StatusChange`: an append failure
  (event resource unwired, DB hiccup, unresolvable org) NEVER aborts the primary
  subscriber write. The subscriber state is the load-bearing fact; the consent row
  rides alongside. All work is wrapped so nothing here can raise into the transaction.

  ## PII discipline

  Every value written is a bounded id (uuid), an enum, a bounded string, a keyed hash,
  or a timestamp. No subject PII enters a `ConsentEvent` row by construction (the
  resource carries no PII columns; the email stays in the subscriber's vault).
  """
  use Ash.Resource.Change

  require Ash.Query

  @withdrawn_statuses [:unsubscribed, :bounced, :complained]

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      maybe_append(changeset, record, opts)
      {:ok, record}
    end)
  end

  # Best-effort append. Nothing here may abort the primary write.
  defp maybe_append(changeset, record, opts) do
    event_resource = Keyword.fetch!(opts, :event_resource)
    org_id = org_id_of(changeset, record)

    if is_binary(org_id) do
      case classify(changeset, record) do
        {:ok, event} ->
          append_row(event_resource, org_id, record, event)

        :noop ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Derive the consent transition (if any) from the post-action record + the changeset.
  # `:granted` when active + consent on file; `:withdrawn` when opted-out / bounced /
  # complained, or consent was cleared. `:noop` when neither is newly true.
  defp classify(changeset, record) do
    status = Map.get(record, :status)
    consent_at = Map.get(record, :consent_at)

    status_changed? =
      changeset.action_type == :create or Ash.Changeset.changing_attribute?(changeset, :status)

    consent_changed? =
      changeset.action_type == :create or Ash.Changeset.changing_attribute?(changeset, :consent_at)

    cond do
      not (status_changed? or consent_changed?) ->
        :noop

      # An opt-out / hard bounce / spam complaint withdraws consent.
      status in @withdrawn_statuses ->
        {:ok, :withdrawn}

      # An active subscriber with consent on file is granted.
      status == :active and not is_nil(consent_at) ->
        {:ok, :granted}

      # Consent EXPLICITLY cleared on an update (had a value, now nil) — a withdrawal.
      # A create with no consent_at is NOT a withdrawal (it is simply "no consent yet"
      # → :none, no event); only clearing a prior consent counts.
      changeset.action_type != :create and consent_changed? and is_nil(consent_at) ->
        {:ok, :withdrawn}

      true ->
        :noop
    end
  end

  defp append_row(event_resource, org_id, record, event) do
    event_resource
    |> Ash.Changeset.for_create(:append, %{
      org_id: org_id,
      subscriber_id: record.id,
      event: event,
      source: Map.get(record, :source),
      purpose: :marketing,
      subject_hash: subject_hash(record.id),
      # Microsecond precision so latest-event-wins is deterministic even for two
      # transitions within the same wall-clock second (a metadata edit that flips
      # consent twice in a burst).
      occurred_at: DateTime.utc_now()
    })
    |> Ash.create!(authorize?: false)

    :ok
  rescue
    _ -> :ok
  end

  # The erasure-surviving keyed pseudonym (trace-sink pattern). Derived while the
  # subject's key exists; stored as bytes. nil if unreconstructable.
  defp subject_hash(subscriber_id) do
    case Samen.WideEvent.for_subject(to_string(subscriber_id)) do
      {:ok, hash} -> hash
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The owning org id — from the changeset attributes, the returned record, or (an
  # update whose loaded struct deselected org_id) a narrow re-select by primary key.
  # `nil` (unresolvable) skips the append rather than failing the write (mirrors the
  # SubscriptionMovement org resolution).
  defp org_id_of(changeset, record) do
    Enum.find_value(
      [
        fn -> Ash.Changeset.get_attribute(changeset, :org_id) end,
        fn -> Map.get(record, :org_id) end,
        fn ->
          record.__struct__
          |> Ash.Query.ensure_selected([:org_id])
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.read_one!(authorize?: false)
          |> Map.get(:org_id)
        end
      ],
      fn resolve ->
        case resolve.() do
          %Ash.NotLoaded{} -> nil
          nil -> nil
          value -> to_string(value)
        end
      end
    )
  rescue
    _ -> nil
  end
end
