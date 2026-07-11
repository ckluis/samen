defmodule Samen.Web.Notifications.Reads do
  @moduledoc """
  The framework notifications read layer (WS-A design §2.4; ADR-016 §4) — the inbox's
  BOUNDED reads plus the `mark_read`/`mark_all_read` writes.

  Every read goes through Ash so `Samen.Policy.OrgScope` applies; the vaulted
  `rendered_body` is resolved through `Samen.Api.PiiResolution.resolve/4` AFTER the
  read — tenant clear / operator `%Masked{}` (→ `••••`). The list read is the
  `ListLive` contract (`(mount, scope, %ListState{}) -> %Page{}`), built on
  `Samen.Web.Reads.page!/3`, so it is BOUNDED BY CONSTRUCTION (`limit(page_size + 1)`,
  hostile page sizes clamped, keyset-stable under concurrent inserts).

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a `%Samen.Masked{}`,
  and has no "show plaintext" path. A resolver failure keeps `%Masked{}` (no plaintext
  downgrade). This is why the realtime path is safe: a subscriber's `handle_info`
  re-reads through `get_notification/3` with its OWN scope, so the SAME notification
  id resolves CLEAR for a tenant subscriber and `••••` for an operator subscriber.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @select [
    :recipient_id,
    :channel,
    :event_type,
    :status,
    :sent_at,
    :read_at,
    :metadata,
    :rendered_body
  ]

  # mark_all_read sweeps at most the kit's hard page cap per call (A3 read-bounding:
  # no unbounded read ever, including the write-side sweep).
  @sweep_limit 200

  @doc """
  Read ONE keyset page of the org's notifications for `scope` — the `ListLive` reads
  contract (ADR-016 §3), newest-first by default. `rendered_body` is plane-resolved
  AFTER paging. Sort/filter fields are bounded NON-VAULTED attributes; the vaulted
  body is never sorted or filtered. On any read error the page is EMPTY — never
  unbounded, never a plaintext downgrade.
  """
  def notifications_page(mount, scope, state) do
    page =
      Mount.resource(mount, Notification)
      |> Ash.Query.ensure_selected(@select)
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:event_type])

    %{page | items: resolve_pii(page.items, mount, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read a SINGLE notification by id for `scope`, `rendered_body` plane-resolved —
  `{:ok, notification}` or `:error`. This is the realtime re-read (design §2.4): each
  PubSub subscriber re-reads the broadcast id through its OWN scope, so masking
  survives the realtime path by construction. A cross-org id reads zero rows under
  OrgScope → `:error` (no existence oracle).
  """
  def get_notification(mount, scope, id) do
    Mount.resource(mount, Notification)
    |> Ash.Query.ensure_selected(@select)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, scope)
    |> case do
      [notification | _] -> {:ok, notification}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  The org's UNREAD notification count for `scope` — feeds the `nav_item` `count`
  badge (AC-G2-7: the badge affordance, finally lit). A DB aggregate — no row set is
  transferred, bounded by construction. `0` on any error (an unlit badge, never a
  crash).
  """
  def unread_count(mount, scope) do
    Mount.resource(mount, Notification)
    |> Ash.Query.filter(is_nil(read_at))
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  @doc """
  Mark ONE notification read for `scope`: flips `read_at` (+ status `:read`). The
  write goes through Ash so OrgScope applies (a cross-org id is not even fetched);
  this module adds NO policy of its own. Touches NO vaulted attribute. `:ok` or
  `{:error, reason}`.
  """
  def mark_read(mount, scope, id) do
    record =
      Mount.resource(mount, Notification)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> Ash.Changeset.for_update(:update, %{read_at: DateTime.utc_now(), status: :read},
          scope: scope
        )
        |> Ash.update(scope: scope)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Mark ALL the org's unread notifications read for `scope` (bounded sweep: at most
  `#{@sweep_limit}` rows per call — an org with more unread than the cap clears the
  oldest #{@sweep_limit} and the badge re-counts honestly). `:ok`.
  """
  def mark_all_read(mount, scope) do
    now = DateTime.utc_now()

    Mount.resource(mount, Notification)
    |> Ash.Query.filter(is_nil(read_at))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@sweep_limit)
    |> Ash.read!(scope: scope)
    |> Enum.each(fn record ->
      record
      |> Ash.Changeset.for_update(:update, %{read_at: now, status: :read}, scope: scope)
      |> Ash.update!(scope: scope)
    end)

    :ok
  rescue
    e -> {:error, e}
  end

  # -- preferences (WS-A design §2.4 "/notifications/settings"; ADR-016 §4) -------

  # A recipient governs a HANDFUL of event types; this cap is a read bound, not a
  # product limit (A3 read-bounding: no unbounded read ever).
  @preferences_limit 200

  @doc """
  The recipient's `NotificationPreference` rows for `scope` — BOUNDED
  (`limit(#{@preferences_limit})`), org-scoped by the kernel policy. No PII by
  construction (bounded id + enums + bools), so no resolver pass is needed. `[]`
  on any read error (an empty grid falls back to the engine defaults — default-on
  in-app, opt-in email — never a crash).
  """
  def preferences(mount, scope, recipient_id) do
    Mount.resource(mount, NotificationPreference)
    |> Ash.Query.filter(recipient_id == ^recipient_id)
    |> Ash.Query.sort(event_type: :asc)
    |> Ash.Query.limit(@preferences_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  UPSERT one per-event-type preference for the recipient (the settings-panel toggle
  write): `changes` is `%{in_app_enabled: bool}` or `%{email_enabled: bool}`. The
  write goes through Ash so `OrgScope` + `RoleAtLeast :member` apply (this module
  adds NO policy of its own); a missing row is created with the engine's defaults
  (in-app ON, email OFF) merged under the toggle. Touches no vaulted attribute
  (the resource has none). `{:ok, preference}` or `{:error, reason}`.
  """
  def set_preference(mount, scope, %{
        org_id: org_id,
        recipient_id: recipient_id,
        event_type: event_type,
        changes: changes
      }) do
    existing =
      Mount.resource(mount, NotificationPreference)
      |> Ash.Query.filter(recipient_id == ^recipient_id)
      |> Ash.Query.filter(event_type == ^event_type)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case existing do
      nil ->
        Mount.resource(mount, NotificationPreference)
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(
            %{
              org_id: org_id,
              recipient_id: recipient_id,
              event_type: event_type,
              in_app_enabled: true,
              email_enabled: false
            },
            changes
          ),
          scope: scope
        )
        |> Ash.create(scope: scope)

      preference ->
        preference
        |> Ash.Changeset.for_update(:update, changes, scope: scope)
        |> Ash.update(scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  # -- private -----------------------------------------------------------------

  # Resolve the vaulted rendered_body through the shared chokepoint; resource + repo
  # from the mount. Fail-safe: on any resolver error the fields stay %Masked{} (no
  # plaintext downgrade).
  defp resolve_pii(records, mount, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, Notification),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
