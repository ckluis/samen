defmodule Samen.Notifications.StatusChange do
  @moduledoc """
  An Ash change that fires a notification when a resource's `:status` attribute
  TRANSITIONS to a listed value — the "system events: … invoice events (existing
  billing state changes)" source of WS-A design §2.3 / ADR-016 §4.

  Attached by a blueprint (the Invoice resource) as:

      change({Samen.Notifications.StatusChange,
        event_prefix: "invoice",
        ref_key: "billing.invoice",
        statuses: [:open, :paid, :void, :uncollectible]})

  ## Semantics

    * Fires ONLY when `:status` is actually changing on this changeset AND the new
      value is in `:statuses` (so an invoice created at its `:draft` default is
      silent; the `draft → open → paid` transitions each fire once).
    * `event_type` is `"<event_prefix>.<new_status>"` (e.g. `"invoice.paid"`) —
      a bounded namespaced label.
    * The notification is addressed to the OWNING ORG as the recipient entity
      (`recipient_id = org_id`) — system events are org-level; per-user fan-out is
      a host concern layered on preferences.
    * Dispatch goes through `Samen.Notifications.Engine.emit/1` — BEST-EFFORT by
      contract: an unwired engine or an engine error NEVER aborts the primary
      write (the invoice transition is the load-bearing state; the notification
      rides alongside). The recipient's `NotificationPreference` gates the record
      (a suppressed event type writes NOTHING — the red path).

  ## PII discipline

  The request carries bounded ids/enums + framework copy only: `subject_ref` is an
  object REF (`samen:billing.invoice:<id>`), never denormalized subject data; the
  `rendered_body` is fixed non-PII framework copy (and is vault-routed by the
  `Notification` resource regardless).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      maybe_emit(changeset, record, opts)
      {:ok, record}
    end)
  end

  defp maybe_emit(changeset, record, opts) do
    statuses = Keyword.get(opts, :statuses, [])
    new_status = Ash.Changeset.get_attribute(changeset, :status)

    if Ash.Changeset.changing_attribute?(changeset, :status) and new_status in statuses do
      prefix = Keyword.fetch!(opts, :event_prefix)
      org_id = org_id_of(changeset, record)

      if is_binary(org_id) do
        Samen.Notifications.Engine.emit(%{
          org_id: org_id,
          recipient_id: org_id,
          event_type: "#{prefix}.#{new_status}",
          channel: :in_app,
          rendered_body: "#{String.capitalize(prefix)} status changed to #{new_status}.",
          subject_ref: subject_ref(opts, record),
          metadata: %{"status" => to_string(new_status)}
        })
      end
    end

    :ok
  rescue
    # Best-effort by contract: NOTHING here may abort the primary write. emit/1
    # already never raises; this belt covers the changeset/record introspection.
    _ -> :ok
  end

  # The owning org id — from the changeset attributes (a create carries it), the
  # returned record, or (an update whose loaded struct deselected org_id) a
  # narrow re-select by primary key. `nil` (unresolvable) skips the emit rather
  # than failing the write.
  defp org_id_of(changeset, record) do
    Enum.find_value(
      [
        fn -> Ash.Changeset.get_attribute(changeset, :org_id) end,
        fn -> Map.get(record, :org_id) end,
        fn ->
          # org_id is NOT select-by-default on Samen resources — an explicit
          # ensure_selected narrow re-read by primary key resolves it.
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

  # The object ref ("samen:<key>:<id>") — a bounded reference the web inbox unfurls
  # through the EXISTING ObjectRef.resolve → object_card path (per-viewer masked).
  defp subject_ref(opts, record) do
    case Keyword.get(opts, :ref_key) do
      nil -> nil
      key -> "samen:#{key}:#{Map.get(record, :id)}"
    end
  end
end
