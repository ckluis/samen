defmodule Samen.Web.NotificationsSourcesTest do
  @moduledoc """
  WS-A A4 UNIT 3 — the design-sanctioned EVENT SOURCES wired into the kernel
  notification engine (design §2.3; ADR-016 §4; AC-G2-6):

    * **SLA breach** (fixes H-9): `SlaBreachWorker` no longer flips `breached=true`
      silently — the flip opens an E5 escalation (ADR-039 §7.4, T41), whose
      `:escalation_due` chain walk emits the `"sla_breach"` notification with a
      `samen:support.ticket:<id>` subject ref (`test/support/automation.ex` mounts
      the `Escalation` primitive for this host).
    * **Chat mentions**: `Samen.Web.Chat.post_message/4` parses `@handle` mentions
      from the PLAINTEXT body (pre-vault, like refs) and notifies each mentioned
      participant (`"chat_mention"`) — never the sender, never the vaulted body.
    * **System events**: a BLOCKED send (`"marketing.send.blocked"`), a FAILED
      send (`"marketing.send.failed"`), and an invoice status TRANSITION
      (`"invoice.paid"` — the "existing billing state changes" source).

  Every source is exercised BOTH ways (the anti-tautology pairing):

    * **green** — the triggering write produces exactly the expected notification
      record (discriminating fields asserted, not just "a row exists");
    * **red path** — a `NotificationPreference` row suppressing the event type
      means the SAME trigger writes NO record at all (suppressed at dispatch, not
      hidden later), while the PRIMARY write (breach flip / posted message /
      blocked send / invoice transition) still lands — the notification is
      best-effort alongside, never load-bearing.

  Kernel sources (worker/Oban/Ash-change) resolve the engine via the app-config
  seam (`config :samen_core, Samen.Notifications.Engine`), wired here to the
  `wn*` web-test Primitives mount; the chat source forwards explicit engine opts
  (the documented `notify:` override).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Marketing.SendWorker
  alias Samen.Scopes.Support.SlaBreachWorker
  alias Samen.Web.Chat
  alias Samen.Web.Mount
  alias Samen.WebTest.Primitives.{Notification, NotificationPreference}

  # An adapter that IS configured but fails delivery — the "marketing.send.failed"
  # trigger (fail-honest path 3, ADR-014).
  defmodule FailingAdapter do
    use Samen.Delivery.Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(_message, _config), do: {:error, :smtp_down}
  end

  setup do
    # Wire the kernel engine's config seam to the web test host's Primitives mount
    # (exactly what a real host does once in config). Cleaned up per test.
    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: NotificationPreference,
      repo: Samen.WebTest.Repo
    )

    # T41 (ADR-039 §7.4): SlaBreachWorker's attention path now routes through the
    # E5 escalation primitive — wire its seam to this host's Escalation mount
    # (test/support/automation.ex) the same way.
    Application.put_env(:samen_core, Samen.Automation.Escalate,
      escalation_module: Samen.WebTest.Automation.Escalation,
      repo: Samen.WebTest.Repo
    )

    on_exit(fn ->
      Application.delete_env(:samen_core, Samen.Notifications.Engine)
      Application.delete_env(:samen_core, Samen.Automation.Escalate)
      Application.delete_env(:samen_core, :delivery_env)
      Application.delete_env(:samen_core, Samen.Scopes.Marketing.SendWorker)
    end)

    :ok
  end

  # -- shared helpers ------------------------------------------------------------

  defp notifications(org_id, event_type) do
    Notification
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(event_type == ^event_type)
    |> Ash.read!(authorize?: false)
  end

  # Suppress `event_type` (in-app) for `recipient_id` — the red-path preference row.
  defp suppress!(org_id, recipient_id, event_type) do
    NotificationPreference
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      recipient_id: recipient_id,
      event_type: event_type,
      in_app_enabled: false
    })
    |> Ash.create!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # SOURCE 1 · SLA breach (H-9: the state flip is no longer silent)
  # ---------------------------------------------------------------------------

  defp seed_breachable_ticket!(org_id) do
    Samen.WebTest.Support.Ticket
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        subject: "Overdue rate confirmation",
        status: :open,
        priority: :urgent,
        sla_breach_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      },
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp run_breach_worker! do
    assert :ok =
             SlaBreachWorker.perform(%Oban.Job{
               args: %{"ticket_abbrev" => "wsk", "repo" => "Samen.WebTest.Repo"}
             })
  end

  defp only_sla_escalation(ticket_id) do
    Samen.WebTest.Automation.Escalation
    |> Ash.Query.filter(kind == "sla_breach")
    |> Ash.Query.filter(dedupe_key == ^to_string(ticket_id))
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp breached?(ticket_id) do
    %{rows: [[breached]]} =
      Samen.WebTest.Repo.query!(
        "SELECT wsk_breached FROM wsk_ticket WHERE wsk_id = $1",
        [Ecto.UUID.dump!(ticket_id)]
      )

    breached
  end

  test "GREEN sla_breach: the breach flip opens an escalation whose step 0 emits the 'sla_breach' notification" do
    org_id = Ash.UUID.generate()
    ticket = seed_breachable_ticket!(org_id)

    run_breach_worker!()

    assert breached?(ticket.id)

    # The breach flip's ONLY bespoke attention path is now Escalate.open/2
    # (ADR-039 §7.4) — it opens the escalation SYNCHRONOUSLY (state :open,
    # dedupe_key = ticket id), but the notification itself fires on the NEXT
    # `:escalation_due` chain-walk tick (step 0, at deadline_at = breach_at,
    # already in the past). Drain that tick to observe the SAME final outcome
    # this test always asserted.
    escalation = only_sla_escalation(ticket.id)
    assert escalation.state == :open
    assert escalation.dedupe_key == to_string(ticket.id)

    AshOban.Test.schedule_and_run_triggers(Samen.WebTest.Automation.Escalation)

    # The escalation primitive's chain-step notification is `event_type:
    # "escalation_step"` for EVERY client kind (SLA breach, dunning, future
    # clients) by design — the unified attention surface (ADR-039 §7.2). What
    # discriminates SLA breach is the escalation's OWN `kind`, carried into the
    # notification's metadata (never a per-kind event_type).
    assert [notification] = notifications(org_id, "escalation_step")
    assert notification.recipient_id == org_id
    assert notification.channel == :in_app
    # The subject travels as an object REF (unfurled per-viewer by the inbox),
    # never denormalized ticket data.
    assert notification.metadata["subject_ref"] == "samen:support.ticket:#{ticket.id}"
    assert notification.metadata["kind"] == "sla_breach"
  end

  test "RED sla_breach: a suppressed preference writes NO record — but the breach flip + escalation still land" do
    org_id = Ash.UUID.generate()
    ticket = seed_breachable_ticket!(org_id)
    # Suppresses the UNIFIED escalation-step event type (§7.2) — the per-kind
    # discriminator lives in metadata now, not the event_type a preference keys on.
    suppress!(org_id, org_id, "escalation_step")

    run_breach_worker!()
    AshOban.Test.schedule_and_run_triggers(Samen.WebTest.Automation.Escalation)

    # The PRIMARY write (the harden fix's state flip) is untouched by suppression…
    assert breached?(ticket.id)
    # …and the suppressed event type wrote NOTHING (no record, not a hidden row).
    assert notifications(org_id, "escalation_step") == []
  end

  # ---------------------------------------------------------------------------
  # SOURCE 2 · chat mentions (@handle on the plaintext, pre-vault)
  # ---------------------------------------------------------------------------

  defp chat_mount do
    Mount.new(:chat, Samen.WebTest.Chat, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())
  end

  defp engine_opts do
    [
      notification_module: Notification,
      preference_module: NotificationPreference,
      repo: Samen.WebTest.Repo
    ]
  end

  defp post_mention!(org_id, chat, body) do
    mount = chat_mount()
    scope = Mount.scope(mount, org_id)

    Chat.post_message(
      mount,
      scope,
      %{
        org_id: org_id,
        thread_id: chat.thread.id,
        participant_id: chat.tenant_participant.id,
        sender_party: :tenant,
        body: body
      },
      broadcast: false,
      notify: engine_opts()
    )
  end

  test "GREEN chat_mention: '@handle' notifies the mentioned participant — never the sender, never the body" do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id)
    org_id = seeded.org_id

    body = "MENTION-BODY-SENTINEL @#{Seeds.second_tenant_handle()} can you re-send the rate con?"
    assert {:ok, message} = post_mention!(org_id, chat, body)

    assert [notification] = notifications(org_id, "chat_mention")
    # The MENTIONED participant is the recipient (matched by non-PII handle).
    assert notification.recipient_id == chat.second_tenant_participant.id
    refute notification.recipient_id == chat.tenant_participant.id
    # Bounded routing metadata only.
    assert notification.metadata["thread_id"] == chat.thread.id
    assert notification.metadata["message_id"] == message.id

    # PII discipline: the vaulted MESSAGE BODY is never copied into the
    # notification — no non-vault column carries the sentinel.
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT wnn_id::text FROM wnn_notification WHERE wnn_metadata::text LIKE $1",
        ["%MENTION-BODY-SENTINEL%"]
      )

    assert rows == []
    refute to_string(notification.event_type) =~ "SENTINEL"
  end

  test "chat_mention does not fire for a body with no mention, nor for a self-mention" do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id)
    org_id = seeded.org_id

    assert {:ok, _} = post_mention!(org_id, chat, "no mentions in this line")
    # The sender @-ing THEMSELVES is not a notification.
    assert {:ok, _} = post_mention!(org_id, chat, "note to self @#{Seeds.tenant_participant_handle()}")

    assert notifications(org_id, "chat_mention") == []
  end

  test "RED chat_mention: a suppressed preference writes NO record — but the message still posts" do
    seeded = Seeds.seed_all()
    chat = Seeds.seed_chat(seeded.org_id)
    org_id = seeded.org_id

    suppress!(org_id, chat.second_tenant_participant.id, "chat_mention")

    assert {:ok, message} =
             post_mention!(org_id, chat, "@#{Seeds.second_tenant_handle()} ping again")

    # The PRIMARY write (the posted message) landed…
    assert is_binary(message.id)
    # …and the suppressed mention wrote NOTHING.
    assert notifications(org_id, "chat_mention") == []
  end

  # ---------------------------------------------------------------------------
  # SOURCE 3 · system events — blocked + failed sends (ADR-014 fail-honest riders)
  # ---------------------------------------------------------------------------

  defp send_args(org_id) do
    %{
      "send_id" => Ash.UUID.generate(),
      "org_id" => org_id,
      "subscriber_id" => Ash.UUID.generate(),
      "repo" => "Samen.WebTest.Repo"
    }
  end

  test "GREEN marketing.send.blocked: an unconfigured adapter in a non-test env notifies" do
    org_id = Ash.UUID.generate()
    # Fail-honest posture: no adapter + prod env → :blocked (never :delivered).
    Application.put_env(:samen_core, :delivery_env, :prod)

    args = send_args(org_id)
    assert {:error, :adapter_unconfigured} = SendWorker.perform(%Oban.Job{args: args})

    assert [notification] = notifications(org_id, "marketing.send.blocked")
    assert notification.recipient_id == org_id
    assert notification.metadata["send_id"] == args["send_id"]
  end

  test "RED marketing.send.blocked: a suppressed preference writes NO record — the send is still blocked" do
    org_id = Ash.UUID.generate()
    Application.put_env(:samen_core, :delivery_env, :prod)
    suppress!(org_id, org_id, "marketing.send.blocked")

    # The fail-honest outcome (the PRIMARY guarantee) is untouched by suppression…
    assert {:error, :adapter_unconfigured} = SendWorker.perform(%Oban.Job{args: send_args(org_id)})
    # …and the suppressed event type wrote NOTHING.
    assert notifications(org_id, "marketing.send.blocked") == []
  end

  test "GREEN marketing.send.failed: an adapter delivery error notifies" do
    org_id = Ash.UUID.generate()
    Application.put_env(:samen_core, Samen.Scopes.Marketing.SendWorker, adapter: FailingAdapter)

    args = send_args(org_id)
    assert {:error, :smtp_down} = SendWorker.perform(%Oban.Job{args: args})

    assert [notification] = notifications(org_id, "marketing.send.failed")
    assert notification.recipient_id == org_id
    assert notification.metadata["send_id"] == args["send_id"]
  end

  test "RED marketing.send.failed: a suppressed preference writes NO record — the send still fails honestly" do
    org_id = Ash.UUID.generate()
    Application.put_env(:samen_core, Samen.Scopes.Marketing.SendWorker, adapter: FailingAdapter)
    suppress!(org_id, org_id, "marketing.send.failed")

    assert {:error, :smtp_down} = SendWorker.perform(%Oban.Job{args: send_args(org_id)})
    assert notifications(org_id, "marketing.send.failed") == []
  end

  # ---------------------------------------------------------------------------
  # SOURCE 4 · system events — invoice state changes (the billing rider)
  # ---------------------------------------------------------------------------

  test "GREEN invoice.paid: an invoice status TRANSITION emits an org-level notification with the invoice ref" do
        %{org_id: org_id, billing: %{invoice: invoice}} = Seeds.seed_all()

    # Seeding created the invoice at :open (a listed status — the create fires
    # "invoice.open"); the transition under test is open → paid.
    assert [_open] = notifications(org_id, "invoice.open")

    invoice
    |> Ash.Changeset.for_update(:update, %{status: :paid, paid_at: DateTime.utc_now()},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.update!()

    assert [notification] = notifications(org_id, "invoice.paid")
    assert notification.recipient_id == org_id
    assert notification.metadata["subject_ref"] == "samen:billing.invoice:#{invoice.id}"
    assert notification.metadata["status"] == "paid"
  end

  test "invoice notifications fire only on a listed status TRANSITION (a no-op update is silent)" do
        %{org_id: org_id, billing: %{invoice: invoice}} = Seeds.seed_all()

    # An update that does NOT change status fires nothing new.
    invoice
    |> Ash.Changeset.for_update(:update, %{amount_paid_cents: 100},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.update!()

    assert notifications(org_id, "invoice.paid") == []
    # Still only the single create-time "invoice.open".
    assert [_open] = notifications(org_id, "invoice.open")
  end

  test "RED invoice.paid: a suppressed preference writes NO record — the invoice still transitions" do
        %{org_id: org_id, billing: %{invoice: invoice}} = Seeds.seed_all()
    suppress!(org_id, org_id, "invoice.paid")

    updated =
      invoice
      |> Ash.Changeset.for_update(:update, %{status: :paid, paid_at: DateTime.utc_now()},
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.update!()

    # The PRIMARY write landed…
    assert updated.status == :paid
    # …and the suppressed event type wrote NOTHING.
    assert notifications(org_id, "invoice.paid") == []
  end
end
