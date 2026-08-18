defmodule Samen.Notifications.DigestTest do
  @moduledoc """
  C8 (T30) — the notification-digest scheduler (spec §C8; c11 ruling; handoff
  done-criterion 3).

  Coverage:

    1. Daily/weekly cadence honored via TIME-TRAVEL (`Digest.run/2`'s `now` is
       an explicit argument — never `Process.sleep`).
    2. Unread notifications batch into ONE `Chokepoint`/`FakeProvider.deliver/2`
       call per due recipient, regardless of count.
    3. `'off'` pref sends nothing.
    4. c11 DEFAULT: no preference row at all still gets a DAILY digest.
    5. Timezone-awareness: two recipients in different fixed-offset zones
       become due at different UTC instants for the SAME local send hour.
    6. Masked-render rules (INV-1) — the `Samen.MaskingCase` 3-proof: send
       plane resolves clear, operator preview masks, sabotage twin (a modeled
       leak past the plane) is caught by `RenderedEmail.provider_payload/1`'s
       fail-closed gate — reusing T29's `render_for_send` seam, never a
       bespoke plaintext path.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  alias Samen.Delivery.{Chokepoint, FakeProvider, RenderedEmail, Rendering}
  alias Samen.Masked
  alias Samen.Notifications.Digest
  alias SamenCore.Support.NotificationFixture.{Notification, NotificationPreference}
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias SamenCore.TestRepo

  @repo TestRepo
  @resource RevealPerson

  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "digest-recipient-SENTINEL@customer.test"}
  end

  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    FakeProvider.reset()
    Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: true}})

    on_exit(fn ->
      Application.delete_env(:samen_core, :delivery_provider)
      Application.delete_env(:samen_core, :delivery_provider_overrides)
    end)

    :ok
  end

  defp org_id, do: Ash.UUID.generate()
  defp recipient_id, do: Ash.UUID.generate()

  defp recipient_struct(id) do
    struct(@resource, %{
      id: id,
      display_name: "Digest Recipient",
      emails: Masked.new("vt_digest_recipient_sentinel_token", :emails)
    })
  end

  defp recipient_loader do
    fn _org_id, recipient_id -> {:ok, %{struct: recipient_struct(recipient_id), resource: @resource}} end
  end

  defp run_opts(overrides \\ []) do
    Keyword.merge(
      [
        notification_module: Notification,
        preference_module: NotificationPreference,
        repo: @repo,
        recipient_loader: recipient_loader(),
        env: :test,
        render_opts: [repo: :unused, vault: OkVault]
      ],
      overrides
    )
  end

  defp create_notification(org, recipient, event_type) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      recipient_id: recipient,
      event_type: event_type,
      channel: :email,
      status: :pending
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_digest_pref(org, recipient, attrs) do
    NotificationPreference
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, recipient_id: recipient, event_type: "__digest__"}, attrs)
    )
    |> Ash.create!(authorize?: false)
  end

  defp fake_calls_for(org, recipient) do
    Enum.filter(FakeProvider.calls(), fn
      {:deliver, %{message: m}} -> m.org_id == org and m.to_subscriber_id == recipient
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # 1 + 2. Daily cadence honored via time-travel; batching -> ONE send.

  describe "daily cadence honored via time-travel; unread notifications batch into ONE send" do
    test "sends once when due, is a no-op before the next window, sends again a day later" do
      org = org_id()
      rec = recipient_id()
      create_digest_pref(org, rec, %{digest_cadence: :daily})

      create_notification(org, rec, "invoice.created")
      create_notification(org, rec, "invoice.created")
      create_notification(org, rec, "ticket.replied")

      t0 = ~U[2026-07-23 09:00:00Z]

      results = Digest.run(t0, run_opts())
      assert {:sent, ^org, ^rec, 3} = Enum.find(results, &match?({:sent, ^org, ^rec, _}, &1))

      # Exactly ONE send for this recipient — batched, not per-notification.
      assert length(fake_calls_for(org, rec)) == 1

      # Immediately after: not due again (same window).
      results2 = Digest.run(DateTime.add(t0, 60, :second), run_opts())
      assert {:skipped, ^org, ^rec, :not_due} = Enum.find(results2, &match?({_, ^org, ^rec, _}, &1))
      assert length(fake_calls_for(org, rec)) == 1

      # A day later (local hour still >= 8): due again.
      t1 = DateTime.add(t0, 86_400, :second)
      results3 = Digest.run(t1, run_opts())
      assert {:sent, ^org, ^rec, _} = Enum.find(results3, &match?({:sent, ^org, ^rec, _}, &1))
      assert length(fake_calls_for(org, rec)) == 2
    end
  end

  describe "weekly cadence honored via time-travel" do
    test "not due after 1 day, due after 7 days" do
      org = org_id()
      rec = recipient_id()
      create_digest_pref(org, rec, %{digest_cadence: :weekly})
      create_notification(org, rec, "invoice.created")

      t0 = ~U[2026-07-23 09:00:00Z]
      results = Digest.run(t0, run_opts())
      assert {:sent, ^org, ^rec, 1} = Enum.find(results, &match?({:sent, ^org, ^rec, _}, &1))

      create_notification(org, rec, "invoice.created")

      one_day_later = DateTime.add(t0, 86_400, :second)
      results2 = Digest.run(one_day_later, run_opts())
      assert {:skipped, ^org, ^rec, :not_due} = Enum.find(results2, &match?({_, ^org, ^rec, _}, &1))

      seven_days_later = DateTime.add(t0, 7 * 86_400, :second)
      results3 = Digest.run(seven_days_later, run_opts())
      # The second notification (still unread) is batched in too.
      assert {:sent, ^org, ^rec, 2} = Enum.find(results3, &match?({:sent, ^org, ^rec, _}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # 3. 'off' pref sends nothing.

  describe "'off' pref sends nothing" do
    test "RED: digest_cadence: :off never sends, no matter how much time passes" do
      org = org_id()
      rec = recipient_id()
      create_digest_pref(org, rec, %{digest_cadence: :off})
      create_notification(org, rec, "invoice.created")

      far_future = DateTime.add(~U[2026-07-23 09:00:00Z], 30 * 86_400, :second)
      results = Digest.run(far_future, run_opts())

      assert {:skipped, ^org, ^rec, :not_due} = Enum.find(results, &match?({_, ^org, ^rec, _}, &1))
      assert fake_calls_for(org, rec) == []
    end
  end

  # ---------------------------------------------------------------------------
  # 4. c11 default: no preference row at all -> DAILY.

  describe "c11 default: no preference row -> daily" do
    test "CONTROL: a recipient with unread notifications and NO digest preference row still gets a digest" do
      org = org_id()
      rec = recipient_id()
      create_notification(org, rec, "invoice.created")

      results = Digest.run(~U[2026-07-23 09:00:00Z], run_opts())
      assert {:sent, ^org, ^rec, 1} = Enum.find(results, &match?({:sent, ^org, ^rec, _}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Timezone-awareness.

  describe "timezone-aware: different zones become due at different UTC instants" do
    test "a UTC recipient is due at 09:00Z; an LA recipient (UTC-8) is NOT yet due at 09:00Z" do
      org = org_id()
      utc_rec = recipient_id()
      la_rec = recipient_id()

      create_digest_pref(org, utc_rec, %{digest_cadence: :daily, digest_timezone: "Etc/UTC"})
      create_digest_pref(org, la_rec, %{digest_cadence: :daily, digest_timezone: "America/Los_Angeles"})

      create_notification(org, utc_rec, "invoice.created")
      create_notification(org, la_rec, "invoice.created")

      # 09:00 UTC = 01:00 LA — before the LA recipient's local send hour (08:00).
      t = ~U[2026-07-23 09:00:00Z]
      results = Digest.run(t, run_opts())

      assert {:sent, ^org, ^utc_rec, _} = Enum.find(results, &match?({_, ^org, ^utc_rec, _}, &1))
      assert {:skipped, ^org, ^la_rec, :not_due} = Enum.find(results, &match?({_, ^org, ^la_rec, _}, &1))

      # 17:00 UTC = 09:00 LA — now due.
      t2 = ~U[2026-07-23 17:00:00Z]
      results2 = Digest.run(t2, run_opts())
      assert {:sent, ^org, ^la_rec, _} = Enum.find(results2, &match?({_, ^org, ^la_rec, _}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Masked-render rules (INV-1) — the MaskingCase 3-proof.

  describe "digest content passes masked-render rules (INV-1)" do
    test "GREEN: the send-plane render resolves the recipient's own address clear" do
      rendered =
        Chokepoint.render_for_send(
          %Samen.Delivery.Message{send_id: Ash.UUID.generate(), org_id: org_id(), to_subscriber_id: recipient_id()},
          recipient_struct(Ash.UUID.generate()),
          @resource,
          repo: :unused,
          vault: OkVault,
          template: fn %{to: to, name: name} -> {"digest", "hi #{name} at #{to}", "<p>hi #{name} at #{to}</p>"} end
        )

      assert rendered.to == "digest-recipient-SENTINEL@customer.test"
      payload = RenderedEmail.provider_payload(rendered)
      assert payload.to == "digest-recipient-SENTINEL@customer.test"
    end

    test "RED: an operator-preview render of the SAME recipient masks — never plaintext, never a vt_ token" do
      rendered =
        Rendering.preview_for_operator(
          %Samen.Delivery.Message{send_id: Ash.UUID.generate(), org_id: org_id(), to_subscriber_id: recipient_id()},
          recipient_struct(Ash.UUID.generate()),
          @resource,
          repo: :unused,
          vault: OkVault,
          grant: DenyAll,
          template: fn %{to: to, name: name} -> {"digest", "hi #{name} at #{to}", "<p>hi #{name} at #{to}</p>"} end
        )

      assert %Masked{} = rendered.to
      refute to_string(rendered.to) =~ "digest-recipient-SENTINEL"

      assert_raise ArgumentError, ~r/Masked/, fn -> RenderedEmail.provider_payload(rendered) end
    end

    test "SABOTAGE TWIN: a hand-forwarded raw vt_ token into the payload is caught (fail-closed, non-vacuous)" do
      leak_attempt = %RenderedEmail{
        send_id: Ash.UUID.generate(),
        to_subscriber_id: recipient_id(),
        to: "vt_digest_recipient_sentinel_token",
        subject: "digest",
        text_body: "leaked vault ref",
        html_body: "<p>leaked</p>"
      }

      assert_raise ArgumentError, ~r/vault token/, fn -> RenderedEmail.provider_payload(leak_attempt) end
    end
  end
end
