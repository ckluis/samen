defmodule Samen.Notifications.EngineTest do
  @moduledoc """
  WS-A A4 UNIT 1 — the kernel notification engine (`Samen.Notifications.Engine`;
  ADR-016 §4). Exercised against a REAL Postgres DB via the `ne*`-abbrev
  `SamenCore.Support.NotificationFixture` mount.

  Guarantees proven (each with a green path AND a red/anti-tautology twin):

    * **Record + dispatch** — `notify/1` writes a `Notification`, vault-routes the
      body, audits, and hands an id-only envelope to the broadcaster.
    * **Preference-aware dispatch (red path)** — a suppressed event type creates
      NO record and dispatches nothing; the discriminating twin (enabled) DOES.
    * **PII discipline (red path)** — the record stores object refs + non-PII copy
      only; `rendered_body` is a `vt_*` token, plaintext appears in no non-vault
      column, and the broadcast envelope carries NO body (Invariant N1).
    * **Fail-closed** — no wired notification module → `{:error, _}`, never a
      silent drop that looks like success.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Notifications.Engine
  alias SamenCore.TestRepo

  alias SamenCore.Support.NotificationFixture.{Notification, NotificationPreference}

  # A test broadcaster that forwards the id-only envelope to the running test pid,
  # so we can assert on EXACTLY what transits the realtime seam (Invariant N1).
  defmodule EchoBroadcaster do
    @behaviour Samen.Notifications.Broadcaster
    @impl true
    def broadcast(envelope) do
      send(:notifications_engine_test_pid |> Process.whereis() || self(), {:broadcast, envelope})
      :ok
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Process.register(self(), :notifications_engine_test_pid)
    on_exit(fn -> :ok end)
    :ok
  end

  defp base_opts do
    [
      notification_module: Notification,
      preference_module: NotificationPreference,
      repo: TestRepo,
      broadcaster: EchoBroadcaster
    ]
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        org_id: Ash.UUID.generate(),
        recipient_id: Ash.UUID.generate(),
        event_type: "invoice.created",
        channel: :in_app,
        rendered_body: "Dear Alice Smith, your invoice #INV-4242 is ready."
      },
      overrides
    )
  end

  defp raw_body_column(id) do
    %{rows: [[col]]} =
      TestRepo.query!(
        "SELECT pii_nen_rendered_body FROM nen_notification WHERE nen_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    col
  end

  # ---------------------------------------------------------------------------
  # AC-G2-5 · record + dispatch + id-only broadcast

  describe "notify/1 — record + dispatch" do
    test "writes a Notification, marks in_app :delivered, and broadcasts an id-only envelope" do
      req = request()

      assert {:ok, notification} = Engine.notify(req, base_opts())

      assert notification.recipient_id == req.recipient_id
      assert notification.event_type == "invoice.created"
      assert notification.channel == :in_app
      # in_app notifications are delivered on write (they land in the inbox).
      assert notification.status == :delivered

      # The realtime seam received the id-only envelope — and ONLY that.
      assert_received {:broadcast, envelope}
      assert envelope.id == notification.id
      assert envelope.org_id == req.org_id
      assert envelope.recipient_id == req.recipient_id
      assert envelope.event_type == "invoice.created"
      assert envelope.channel == :in_app
    end

    test "an email channel notification starts :pending (handed to the delivery adapter downstream)" do
      # Email is opt-in — enable it via a preference row so it isn't suppressed.
      req = request(%{channel: :email, event_type: "digest.weekly"})

      NotificationPreference
      |> Ash.Changeset.for_create(:create, %{
        org_id: req.org_id,
        recipient_id: req.recipient_id,
        event_type: "digest.weekly",
        email_enabled: true
      })
      |> Ash.create!(authorize?: false)

      assert {:ok, notification} = Engine.notify(req, base_opts())
      assert notification.channel == :email
      assert notification.status == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH · preference-aware dispatch (suppressed event → NO record)

  describe "preference-aware dispatch (red path + anti-tautology twin)" do
    test "a SUPPRESSED (in_app_enabled: false) event type creates NO record and dispatches nothing" do
      req = request(%{event_type: "noise.event"})

      # Opt the recipient OUT of this event type.
      NotificationPreference
      |> Ash.Changeset.for_create(:create, %{
        org_id: req.org_id,
        recipient_id: req.recipient_id,
        event_type: "noise.event",
        in_app_enabled: false
      })
      |> Ash.create!(authorize?: false)

      assert {:ok, :suppressed} = Engine.notify(req, base_opts())

      # No record was written for this recipient+event.
      count = count_records(req.recipient_id, "noise.event")
      assert count == 0, "a suppressed event must create NO notification record, got #{count}"

      # Nothing was broadcast.
      refute_received {:broadcast, _}
    end

    test "ANTI-TAUTOLOGY: the SAME recipient with in_app_enabled: true DOES get a record" do
      # If suppression were unconditional, this twin would also produce zero records —
      # proving the gate above is a real preference check, not a constant.
      req = request(%{event_type: "wanted.event"})

      NotificationPreference
      |> Ash.Changeset.for_create(:create, %{
        org_id: req.org_id,
        recipient_id: req.recipient_id,
        event_type: "wanted.event",
        in_app_enabled: true
      })
      |> Ash.create!(authorize?: false)

      assert {:ok, %{} = notification} = Engine.notify(req, base_opts())
      assert notification.event_type == "wanted.event"
      assert count_records(req.recipient_id, "wanted.event") == 1
      assert_received {:broadcast, _}
    end

    test "default-on: with NO preference row, in_app is delivered (opt-out, not opt-in)" do
      req = request(%{event_type: "default.on"})
      assert {:ok, %{}} = Engine.notify(req, base_opts())
      assert count_records(req.recipient_id, "default.on") == 1
    end

    test "email is opt-IN: with NO preference row, an email event is suppressed" do
      req = request(%{event_type: "email.optin", channel: :email})
      assert {:ok, :suppressed} = Engine.notify(req, base_opts())
      assert count_records(req.recipient_id, "email.optin") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # RED PATH · PII discipline — no denormalized plaintext, id-only envelope

  describe "PII discipline (the load-bearing masking rule)" do
    test "the record for a PII-bearing subject contains NO vault-token plaintext and NO vaulted-field copy" do
      plaintext = "Dear Alice Smith, SSN 111-22-3333, your invoice #INV-9 is ready."
      subject_ref = "samen:crm.person:#{Ash.UUID.generate()}"

      req =
        request(%{
          event_type: "invoice.created",
          rendered_body: plaintext,
          subject_ref: subject_ref
        })

      assert {:ok, notification} = Engine.notify(req, base_opts())

      # 1. The rendered_body domain column is a vt_ token — NEVER the plaintext.
      body_col = raw_body_column(notification.id)
      assert String.starts_with?(body_col, "vt_"),
             "rendered_body must be a vt_ token, got: #{inspect(body_col)}"

      refute body_col =~ "Alice Smith"
      refute body_col =~ "111-22-3333"
      refute body_col =~ "INV-9"

      # 2. NO other non-vault column holds a copy of the plaintext (scan the whole row).
      %{columns: cols, rows: [row]} =
        TestRepo.query!("SELECT * FROM nen_notification WHERE nen_id = $1",
          [Ecto.UUID.dump!(notification.id)])

      Enum.zip(cols, row)
      |> Enum.each(fn {col, val} ->
        val_str = to_string_safe(val)
        refute val_str =~ "Alice Smith", "plaintext leaked into column #{col}"
        refute val_str =~ "111-22-3333", "SSN leaked into column #{col}"
      end)

      # 3. metadata stores the object REF (a reference), not denormalized subject PII.
      %{rows: [[meta_json]]} =
        TestRepo.query!("SELECT nen_metadata FROM nen_notification WHERE nen_id = $1",
          [Ecto.UUID.dump!(notification.id)])

      meta = if is_binary(meta_json), do: Jason.decode!(meta_json), else: meta_json
      assert meta["subject_ref"] == subject_ref
      refute inspect(meta) =~ "Alice Smith"
    end

    test "the broadcast envelope carries NO rendered body (Invariant N1)" do
      req = request(%{rendered_body: "Secret plaintext body for Bob Jones."})
      assert {:ok, _} = Engine.notify(req, base_opts())

      assert_received {:broadcast, envelope}
      # The envelope has EXACTLY the id-only routing keys — no body field, no PII.
      assert Map.keys(envelope) |> Enum.sort() ==
               [:channel, :event_type, :id, :org_id, :recipient_id]

      refute inspect(envelope) =~ "Secret plaintext"
      refute inspect(envelope) =~ "Bob Jones"
    end

    test "a plain Ash.read of the notification masks rendered_body (%Masked{} by default)" do
      req = request(%{rendered_body: "Confidential notification for Carol."})
      assert {:ok, notification} = Engine.notify(req, base_opts())

      {:ok, [loaded]} =
        Notification
        |> Ash.Query.filter(id == ^notification.id)
        |> Ash.Query.select([:id, :rendered_body])
        |> Ash.read(authorize?: false)

      assert %Samen.Masked{} = loaded.rendered_body
      refute inspect(loaded) =~ "Confidential notification for Carol"
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed · a missing notification module is an honest error, not a silent drop

  describe "fail-closed" do
    test "no wired notification module → {:error, :no_notification_module}" do
      assert {:error, :no_notification_module} =
               Engine.notify(request(), repo: TestRepo, broadcaster: EchoBroadcaster)

      refute_received {:broadcast, _}
    end

    test "an incomplete request (missing recipient) → {:error, :incomplete_request}" do
      req = request() |> Map.delete(:recipient_id)
      assert {:error, :incomplete_request} = Engine.notify(req, base_opts())
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp count_records(recipient_id, event_type) do
    Notification
    |> Ash.Query.filter(recipient_id == ^recipient_id)
    |> Ash.Query.filter(event_type == ^event_type)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(nil), do: ""
  defp to_string_safe(v), do: inspect(v)
end
