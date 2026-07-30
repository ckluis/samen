defmodule Samen.Notifications.Digest do
  @moduledoc """
  The C8 notification-digest scheduler (spec §C8; c11 ruling; T30) —
  vendor-generic, family-agnostic (INV-4): batches a recipient's UNREAD
  `Notification` rows into ONE email per due cadence window and sends it
  through the SAME `Samen.Delivery.Chokepoint` every other family uses.

  ## Cadence + timezone (c11: "Daily digest default, per-user cadence pref
  (off/daily/weekly), timezone-aware from existing user prefs")

  Read from the RESERVED `event_type == "__digest__"` sentinel row on
  `Samen.Scopes.Primitives.Blueprint`'s `NotificationPreference` (see that
  module's moduledoc for why it rides the existing preference resource rather
  than a new one). No row for a recipient means the c11 DEFAULT applies:
  `digest_cadence: :daily`, `digest_timezone: "Etc/UTC"`.

  `due?/4` is PURE and time-travel testable — `run/2`'s `now` is an explicit
  argument (never `DateTime.utc_now/0` internally), so tests advance the clock
  instead of sleeping. `digest_last_sent_at` is the watermark: a period has
  elapsed (`>= 1 day` / `>= 7 days` since the last send, or never sent) AND the
  recipient's LOCAL wall-clock hour has reached the send hour (default 08:00).

  ## Timezone conversion — a deliberate, dependency-free simplification

  `samen_core` carries no tzdata dependency (INV-4 vendor-free; no new dep for
  this task). `to_local/2` shifts UTC by a FIXED offset for a small curated set
  of common IANA zone names (`@offsets`) — DST is NOT modeled (a zone's
  offset does not change across the year). An unrecognized zone name falls
  back to UTC (0), never crashes. This is a named GAP (see T30 work/summary.md)
  for a future tzdata-backed replacement; the cadence/batching/masking
  mechanics this module owns are independent of that swap.

  ## Batching -> ONE send (never per-notification)

  Exactly one `Samen.Delivery.Chokepoint.send/2` call per due recipient,
  regardless of how many unread notifications exist — the digest CONTENT lists
  bounded `event_type` + count pairs (e.g. `"invoice.created: 2"`), never the
  raw vaulted `rendered_body` of any individual notification (no per-item
  reveal-grant machinery needed; a recipient's own resolved address/name IS
  legitimately theirs to see on the send plane).

  ## Masked-render rules (INV-1)

  The digest body is built via `Samen.Delivery.Rendering.render_for_send/4` —
  the SAME masking seam every other C2/C3 send uses (never a bespoke plaintext
  path) — and `Samen.Delivery.RenderedEmail.provider_payload/1` (fail-closed:
  raises on a `%Samen.Masked{}` value or a `vt_` token) gates the outbound
  payload before it ever reaches the adapter config. A digest built for an
  operator-preview plane therefore masks exactly like every other C3 render;
  see `samen_core/test/delivery/digest_test.exs` for the green/red/sabotage
  three-proof.

  ## Configuration

  Reads `notification_module` / `preference_module` / `repo` from the SAME
  `config :samen_core, Samen.Notifications.Engine, ...` slot every host
  already wires (no duplicate config needed); `opts` may override any of
  them plus:

    * `:recipient_loader` — required, `fn(org_id, recipient_id) -> {:ok,
      %{struct: recipient, resource: resource_module}} | :error` (host-specific:
      only the host knows which resource a `recipient_id` names — mirrors the
      reference delivery adapter's `:resolve_recipient` injectable-glue
      precedent, ADR-038 §4.1).
    * `:fallback_adapter` / `:fallback_config` — threaded to `Chokepoint.send/2`
      exactly like every other C2 family.
    * `:env` — threaded to `Chokepoint.send/2` (`:test` enables the LocalSink
      fallback).
  """

  require Ash.Query

  alias Samen.Delivery.{Chokepoint, Message, Rendering}
  alias Samen.Delivery.RenderedEmail

  @send_local_hour 8

  # A small curated set of common IANA zone names -> FIXED UTC offset minutes
  # (no DST modeling — see moduledoc "Timezone conversion"). Not exhaustive by
  # design; unknown names fall back to UTC.
  @offsets %{
    "Etc/UTC" => 0,
    "UTC" => 0,
    "America/New_York" => -300,
    "America/Chicago" => -360,
    "America/Denver" => -420,
    "America/Los_Angeles" => -480,
    "Europe/London" => 0,
    "Europe/Paris" => 60,
    "Europe/Berlin" => 60,
    "Asia/Kolkata" => 330,
    "Asia/Tokyo" => 540,
    "Australia/Sydney" => 600
  }

  @cadence_period_seconds %{"daily" => 86_400, "weekly" => 7 * 86_400}

  @doc "UTC-offset minutes for `timezone`; an unrecognized zone falls back to UTC (0)."
  @spec offset_minutes(String.t() | nil) :: integer()
  def offset_minutes(timezone), do: Map.get(@offsets, timezone, 0)

  @doc "Shift a UTC `DateTime` to `timezone`'s local wall-clock time (fixed-offset)."
  @spec to_local(DateTime.t(), String.t() | nil) :: DateTime.t()
  def to_local(%DateTime{} = utc_dt, timezone) do
    DateTime.add(utc_dt, offset_minutes(timezone) * 60, :second)
  end

  @doc """
  PURE due-check (no I/O, no sleep — time-travel testable). `cadence` is
  `:off | :daily | :weekly` (or the equivalent string); `last_sent_at` nil
  means never sent.
  """
  @spec due?(atom() | String.t() | nil, String.t() | nil, DateTime.t() | nil, DateTime.t()) :: boolean()
  def due?(cadence, _timezone, _last_sent_at, _now) when cadence in [nil, "off", :off], do: false

  def due?(cadence, timezone, last_sent_at, %DateTime{} = now) do
    period = Map.fetch!(@cadence_period_seconds, to_string(cadence))
    elapsed_ok? = is_nil(last_sent_at) or DateTime.diff(now, last_sent_at, :second) >= period
    local_hour_ok? = to_local(now, timezone).hour >= @send_local_hour
    elapsed_ok? and local_hour_ok?
  end

  @doc """
  Run one digest pass at `now`. Returns a list of per-recipient outcomes:
  `{:sent, org_id, recipient_id, unread_count}` | `{:skipped, org_id,
  recipient_id, :not_due | :no_unread}` | `{:error, org_id, recipient_id, reason}`.
  """
  @spec run(DateTime.t(), keyword()) :: [tuple()]
  def run(%DateTime{} = now, opts \\ []) do
    notification_mod = fetch!(opts, :notification_module)
    preference_mod = fetch!(opts, :preference_module)
    repo = fetch!(opts, :repo)
    recipient_loader = fetch!(opts, :recipient_loader)

    for {org_id, recipient_id} <- unread_recipients(notification_mod) do
      process_recipient(org_id, recipient_id, notification_mod, preference_mod, repo, recipient_loader, now, opts)
    end
  end

  # ---------------------------------------------------------------------------

  defp process_recipient(org_id, recipient_id, notification_mod, preference_mod, repo, recipient_loader, now, opts) do
    pref = digest_preference(preference_mod, org_id, recipient_id)
    cadence = pref_field(pref, :digest_cadence, :daily)
    timezone = pref_field(pref, :digest_timezone, "Etc/UTC")
    last_sent_at = pref_field(pref, :digest_last_sent_at, nil)

    cond do
      not due?(cadence, timezone, last_sent_at, now) ->
        {:skipped, org_id, recipient_id, :not_due}

      true ->
        unread = unread_notifications(notification_mod, org_id, recipient_id)

        if unread == [] do
          {:skipped, org_id, recipient_id, :no_unread}
        else
          case send_digest(org_id, recipient_id, unread, recipient_loader, opts) do
            :ok ->
              advance_watermark(preference_mod, repo, org_id, recipient_id, pref, now)
              {:sent, org_id, recipient_id, length(unread)}

            {:error, reason} ->
              {:error, org_id, recipient_id, reason}
          end
        end
    end
  end

  defp pref_field(nil, :digest_cadence, default), do: default
  defp pref_field(nil, :digest_timezone, default), do: default
  defp pref_field(nil, :digest_last_sent_at, default), do: default
  defp pref_field(pref, field, _default), do: Map.get(pref, field)

  # `org_id`/`inserted_at`/`updated_at` are the Samen.Resource "core columns"
  # (`Samen.Transformers.CoreAttributes`) — NOT select-by-default (the
  # `Samen.RedPath`/`Samen.Identity.Invite`/`Samen.Auth.SessionCreate` house
  # idiom: `Ash.Query.select([:id, :org_id, ...])` whenever a caller genuinely
  # needs the value back, rather than relying on the default read).

  defp unread_recipients(notification_mod) do
    notification_mod
    |> Ash.Query.filter(status != :read)
    |> Ash.Query.select([:id, :org_id, :recipient_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.org_id, &1.recipient_id})
    |> Enum.uniq()
  end

  defp unread_notifications(notification_mod, org_id, recipient_id) do
    notification_mod
    |> Ash.Query.filter(org_id == ^org_id and recipient_id == ^recipient_id and status != :read)
    |> Ash.Query.select([:id, :org_id, :recipient_id, :event_type, :status])
    |> Ash.read!(authorize?: false)
  end

  defp digest_preference(preference_mod, org_id, recipient_id) do
    preference_mod
    |> Ash.Query.filter(org_id == ^org_id and recipient_id == ^recipient_id and event_type == "__digest__")
    |> Ash.Query.select([:id, :org_id, :recipient_id, :event_type, :digest_cadence, :digest_timezone, :digest_last_sent_at])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp advance_watermark(preference_mod, _repo, org_id, recipient_id, nil, now) do
    preference_mod
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      recipient_id: recipient_id,
      event_type: "__digest__",
      digest_last_sent_at: DateTime.truncate(now, :second)
    })
    |> Ash.create!(authorize?: false)
  end

  defp advance_watermark(_preference_mod, _repo, _org_id, _recipient_id, pref, now) do
    pref
    |> Ash.Changeset.for_update(:update, %{digest_last_sent_at: DateTime.truncate(now, :second)})
    |> Ash.update!(authorize?: false)
  end

  defp send_digest(org_id, recipient_id, unread, recipient_loader, opts) do
    case recipient_loader.(org_id, recipient_id) do
      {:ok, %{struct: recipient, resource: resource}} ->
        message = %Message{send_id: Ash.UUID.generate(), org_id: org_id, to_subscriber_id: recipient_id}

        # `:render_opts` (NOT this module's own `:repo`, which names the
        # Ash/notification repo) threads `:repo`/`:vault`/`:grant` to the
        # PiiResolution seam — a distinct concept, kept in its own key so the
        # two never collide.
        render_opts = Keyword.get(opts, :render_opts, [])

        rendered =
          Rendering.render_for_send(
            message,
            recipient,
            resource,
            Keyword.put(render_opts, :template, &digest_template(unread, &1))
          )

        # Fail-closed INV-1 gate: raises on a %Masked{} value or a vt_ token —
        # a masked/unresolved render can NEVER reach the send config.
        payload = RenderedEmail.provider_payload(rendered)

        fallback_config =
          opts
          |> Keyword.get(:fallback_config, %{})
          |> Map.merge(%{
            subject: payload.subject,
            text_body: payload.text_body,
            html_body: payload[:html_body],
            resolve_recipient: fn _msg -> {:ok, payload.to} end
          })

        case Chokepoint.send(message,
               fallback_adapter: Keyword.get(opts, :fallback_adapter),
               fallback_config: fallback_config,
               env: Keyword.get(opts, :env, :prod)
             ) do
          {:ok, _receipt} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :no_recipient}
    end
  end

  # Bounded event_type + count pairs ONLY — never a per-notification rendered
  # body (no PII beyond the recipient's own resolved to/name).
  defp digest_template(unread, %{to: to, name: name}) do
    counts = Enum.frequencies_by(unread, & &1.event_type)
    count = length(unread)
    plural = if count == 1, do: "", else: "s"

    lines_text = counts |> Enum.map(fn {type, n} -> "  - #{type}: #{n}" end) |> Enum.join("\n")

    # HTML body: every recipient/tenant-derived value (name, to) AND the
    # event_type strings are escaped through the sanctioned `Phoenix.HTML.Safe`
    # seam (`Rendering.html_safe/1`) — the SAME protocol `%Samen.Masked{}`
    # implements, so plaintext is entity-encoded (F3 XSS fix, T111) and a masked
    # value still renders `••••`. Counts are integers (no escaping needed).
    lines_html =
      counts
      |> Enum.map_join("", fn {type, n} -> "<li>#{Rendering.html_safe(type)}: #{n}</li>" end)

    subject = "Your digest: #{count} update#{plural}"

    text_body =
      "Hello #{name},\n\n" <>
        "This message was sent to #{to}.\n" <>
        "You have #{count} unread notification#{plural}:\n#{lines_text}\n"

    html_body =
      "<p>Hello #{Rendering.html_safe(name)},</p>" <>
        "<p>This message was sent to #{Rendering.html_safe(to)}.</p>" <>
        "<p>You have #{count} unread notification#{plural}:</p><ul>#{lines_html}</ul>"

    {subject, text_body, html_body}
  end

  defp fetch!(opts, key) do
    Keyword.get(opts, key) || Application.get_env(:samen_core, Samen.Notifications.Engine, [])[key] ||
      raise "Samen.Notifications.Digest: missing required #{inspect(key)} (pass as an opt or " <>
              "`config :samen_core, Samen.Notifications.Engine, #{key}: ...`)"
  end
end
