defmodule Samen.Delivery.LifecycleSendTest do
  @moduledoc """
  T28/C2 — the outbound lifecycle actually sends + the suppression chokepoint
  (ADR-038 §4.3/§4.1; handoff done-criteria 1–3).

  Coverage:

    1. TABLE-DRIVEN: each of the FOUR C2 send families (auth emails A2/A3/A5,
       notification digests, ticket replies, marketing sends) reaches
       `Samen.Delivery.FakeProvider` with the correct token-only envelope once a
       provider is configured via `Samen.Delivery.ProviderSelection` — this is
       the T27-shipped-but-unwired chokepoint T28 wires in. Unconfigured
       (anywhere) still terminates fail-honest (never a faked `:ok`).
    2. SUPPRESSION: a suppressed `(org_id, subscriber_id)` is refused AT THE
       CHOKEPOINT (red), with an unsuppressed control (green) proving the gate
       is a real discriminator, not a constant. `FakeProvider.deliver/2` is
       NEVER called for the suppressed case.
    3. NO SEND PATH BYPASSES THE CHOKEPOINT — moved to
       `Samen.Delivery.ChokepointAntiBypassProbeTest` (T30 hardening: the
       original scoped-8-file grep here was defeated by a rogue module added
       in a NEW file outside the hardcoded allowlist; the replacement is a
       FULL-TREE scan, see that file for the rationale + the rogue-file red
       proof).
    4. Provider message id (ADR-038 §4.1) is persisted onto the delivery record
       — proven against a REAL Postgres `Send` row
       (`SamenCore.Support.SuppressionFixture.Send`, the marketing family's
       delivery record; the ONE family with a persisted resource today).
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{AuthMailer, Chokepoint, FakeProvider}
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Notifications.EmailDispatchWorker
  alias Samen.Scopes.Marketing.SendWorker
  alias SamenCore.Support.SuppressionFixture
  alias SamenCore.TestRepo

  # ---------------------------------------------------------------------------
  # Setup / config sandboxing (every Application.put_env this file touches is
  # saved + restored, mirroring delivery_lifecycle_test.exs's discipline).

  @env_keys [
    :delivery_provider,
    :delivery_provider_overrides,
    :delivery_env,
    :marketing_send_module,
    :marketing_repo
  ]
  @app_keys [EmailWorker, SendWorker, EmailDispatchWorker, Chokepoint]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev_env = for k <- @env_keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}
    prev_app = for k <- @app_keys, into: %{}, do: {k, Application.get_env(:samen_core, k)}

    FakeProvider.reset()

    on_exit(fn ->
      for {k, v} <- prev_env, do: restore(k, v)
      for {k, v} <- prev_app, do: restore(k, v)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  # A configured fake provider, selected via ProviderSelection (the T27-shipped,
  # T28-wired path) rather than any per-worker legacy config — this is the exact
  # gap the handoff names: "kill the :blocked terminal for configured providers".
  defp configure_fake_provider(configured?) do
    Application.put_env(:samen_core, :delivery_provider, {FakeProvider, %{configured: configured?}})
    Application.delete_env(:samen_core, :delivery_provider_overrides)
    Application.delete_env(:samen_core, EmailWorker)
    Application.delete_env(:samen_core, SendWorker)
    Application.delete_env(:samen_core, EmailDispatchWorker)
  end

  defp deconfigure_everywhere do
    Application.delete_env(:samen_core, :delivery_provider)
    Application.delete_env(:samen_core, :delivery_provider_overrides)
    Application.delete_env(:samen_core, EmailWorker)
    Application.delete_env(:samen_core, SendWorker)
    Application.delete_env(:samen_core, EmailDispatchWorker)
    Application.put_env(:samen_core, :delivery_env, :prod)
  end

  defp job(args), do: %Oban.Job{args: args}

  # Did FakeProvider record a :deliver call whose Message matches org/subscriber?
  defp delivered_to?(org_id, subscriber_id) do
    Enum.any?(FakeProvider.calls(), fn
      {:deliver, %{message: m}} -> m.org_id == org_id and m.to_subscriber_id == subscriber_id
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # 1. TABLE-DRIVEN — all FOUR C2 send families reach the fake provider.

  describe "table-driven: the four C2 send families reach the configured provider" do
    test "auth email, marketing send, notification digest, and ticket reply all dispatch" do
      configure_fake_provider(true)
      org_id = Ash.UUID.generate()

      families = [
        {"auth email (A2/A3/A5)",
         fn ->
           sub = Ash.UUID.generate()
           {AuthMailer.dispatch(:email_verify, credential_id: sub, org_id: org_id), sub}
         end},
        {"marketing send",
         fn ->
           sub = Ash.UUID.generate()

           result =
             SendWorker.perform(
               job(%{
                 "send_id" => Ash.UUID.generate(),
                 "org_id" => org_id,
                 "subscriber_id" => sub
               })
             )

           {result, sub}
         end},
        {"notification digest",
         fn ->
           sub = Ash.UUID.generate()

           result =
             EmailDispatchWorker.perform(
               job(%{
                 "send_id" => Ash.UUID.generate(),
                 "org_id" => org_id,
                 "subscriber_id" => sub,
                 "template_id" => "digest.weekly"
               })
             )

           {result, sub}
         end},
        {"ticket reply",
         fn ->
           sub = Ash.UUID.generate()

           result =
             EmailDispatchWorker.perform(
               job(%{
                 "send_id" => Ash.UUID.generate(),
                 "org_id" => org_id,
                 "subscriber_id" => sub,
                 "template_id" => "support.ticket_reply"
               })
             )

           {result, sub}
         end}
      ]

      for {label, run} <- families do
        FakeProvider.reset()
        {result, subscriber_id} = run.()

        assert match?({:ok, _}, result) or result == :ok,
               "#{label}: expected a genuine send, got #{inspect(result)}"

        assert delivered_to?(org_id, subscriber_id),
               "#{label}: FakeProvider.deliver/2 was never called with the expected envelope " <>
                 "(calls=#{inspect(FakeProvider.calls())})"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 1b. Unconfigured EVERYWHERE still terminates fail-honest — never a faked :ok.

  describe "unconfigured (anywhere) is fail-honest for all four families" do
    test "auth email is blocked, never faked to :ok" do
      deconfigure_everywhere()

      assert {:error, :adapter_unconfigured} =
               AuthMailer.dispatch(:password_reset, credential_id: "cred-1")

      assert FakeProvider.calls() == []
    end

    test "marketing send is blocked, never faked to :delivered" do
      deconfigure_everywhere()

      assert {:error, :adapter_unconfigured} =
               SendWorker.perform(
                 job(%{
                   "send_id" => Ash.UUID.generate(),
                   "org_id" => Ash.UUID.generate(),
                   "subscriber_id" => Ash.UUID.generate()
                 })
               )

      assert FakeProvider.calls() == []
    end

    test "notification digest is blocked, never faked to :sent" do
      deconfigure_everywhere()

      assert {:error, :adapter_unconfigured} =
               EmailDispatchWorker.perform(
                 job(%{
                   "send_id" => Ash.UUID.generate(),
                   "org_id" => Ash.UUID.generate(),
                   "subscriber_id" => Ash.UUID.generate(),
                   "template_id" => "digest.weekly"
                 })
               )

      assert FakeProvider.calls() == []
    end

    test "ticket reply is blocked, never faked to :sent" do
      deconfigure_everywhere()

      assert {:error, :adapter_unconfigured} =
               EmailDispatchWorker.perform(
                 job(%{
                   "send_id" => Ash.UUID.generate(),
                   "org_id" => Ash.UUID.generate(),
                   "subscriber_id" => Ash.UUID.generate(),
                   "template_id" => "support.ticket_reply"
                 })
               )

      assert FakeProvider.calls() == []
    end

    test "anti-tautology: the SAME configured provider genuinely dispatches (RP-D1 non-vacuous)" do
      configure_fake_provider(true)
      Application.put_env(:samen_core, :delivery_env, :prod)

      assert {:ok, _} = AuthMailer.dispatch(:email_verify, credential_id: "cred-x", org_id: "org-x")
      assert delivered_to?("org-x", "cred-x")
    end
  end

  # ---------------------------------------------------------------------------
  # 2. SUPPRESSION at the chokepoint — red path + unsuppressed control.

  defmodule PairSuppression do
    @moduledoc "Test-only suppression check: a fixed set of (org_id, subscriber_id) pairs."
    def suppressed?(org_id, subscriber_id) do
      Process.get(:lifecycle_send_test_suppressed_pairs, MapSet.new())
      |> MapSet.member?({org_id, subscriber_id})
    end
  end

  defp suppress!(org_id, subscriber_id) do
    Application.put_env(:samen_core, Chokepoint, suppression_module: PairSuppression)

    current = Process.get(:lifecycle_send_test_suppressed_pairs, MapSet.new())
    Process.put(:lifecycle_send_test_suppressed_pairs, MapSet.put(current, {org_id, subscriber_id}))
  end

  describe "suppression enforced AT THE CHOKEPOINT (spec C2)" do
    test "a suppressed recipient is refused — the provider is NEVER called" do
      configure_fake_provider(true)
      org_id = Ash.UUID.generate()
      suppressed_sub = Ash.UUID.generate()
      suppress!(org_id, suppressed_sub)

      assert {:error, :suppressed} =
               AuthMailer.dispatch(:email_verify, credential_id: suppressed_sub, org_id: org_id)

      refute delivered_to?(org_id, suppressed_sub)
      assert FakeProvider.calls() == [], "a suppressed send must NEVER reach the provider"
    end

    test "ANTI-TAUTOLOGY: an UNsuppressed recipient (same org) genuinely dispatches" do
      configure_fake_provider(true)
      org_id = Ash.UUID.generate()
      suppressed_sub = Ash.UUID.generate()
      control_sub = Ash.UUID.generate()
      suppress!(org_id, suppressed_sub)

      # The suppressed one is still refused...
      assert {:error, :suppressed} =
               AuthMailer.dispatch(:email_verify, credential_id: suppressed_sub, org_id: org_id)

      # ...but an unsuppressed subscriber in the SAME org is not swept up by a
      # constant/always-refuse gate.
      assert {:ok, _} = AuthMailer.dispatch(:email_verify, credential_id: control_sub, org_id: org_id)
      assert delivered_to?(org_id, control_sub)
    end

    test "suppression applies uniformly across ALL FOUR send families (single chokepoint)" do
      configure_fake_provider(true)
      org_id = Ash.UUID.generate()
      suppressed_sub = Ash.UUID.generate()
      suppress!(org_id, suppressed_sub)

      results = [
        AuthMailer.dispatch(:email_verify, credential_id: suppressed_sub, org_id: org_id),
        SendWorker.perform(
          job(%{"send_id" => Ash.UUID.generate(), "org_id" => org_id, "subscriber_id" => suppressed_sub})
        ),
        EmailDispatchWorker.perform(
          job(%{
            "send_id" => Ash.UUID.generate(),
            "org_id" => org_id,
            "subscriber_id" => suppressed_sub,
            "template_id" => "digest.weekly"
          })
        ),
        EmailDispatchWorker.perform(
          job(%{
            "send_id" => Ash.UUID.generate(),
            "org_id" => org_id,
            "subscriber_id" => suppressed_sub,
            "template_id" => "support.ticket_reply"
          })
        )
      ]

      for result <- results do
        assert {:error, :suppressed} = result
      end

      assert FakeProvider.calls() == [],
             "no family may bypass the chokepoint's suppression gate"
    end

    test "unwired (no suppression_module configured) degrades OPEN — honest 'nothing to check'" do
      configure_fake_provider(true)
      Application.delete_env(:samen_core, Chokepoint)

      refute Chokepoint.suppressed?("org-y", "sub-y")
    end

    test "a suppression check that RAISES fails CLOSED (never silently lets a send through)" do
      defmodule RaisingSuppression do
        def suppressed?(_org_id, _subscriber_id), do: raise("boom")
      end

      Application.put_env(:samen_core, Chokepoint, suppression_module: RaisingSuppression)
      assert Chokepoint.suppressed?("org-z", "sub-z")
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Provider message id persisted on the delivery record (ADR-038 §4.1).

  describe "provider message id persisted on the delivery record" do
    setup do
      Application.put_env(:samen_core, :marketing_send_module, SuppressionFixture.Send)
      Application.put_env(:samen_core, :marketing_repo, TestRepo)
      :ok
    end

    test "a delivered marketing send persists the provider's message id onto the Send row" do
      configure_fake_provider(true)
      org_id = Ash.UUID.generate()

      {:ok, subscriber} =
        SuppressionFixture.Subscriber
        |> Ash.Changeset.for_create(:create, %{org_id: org_id})
        |> Ash.create(authorize?: false)

      {:ok, send_row} =
        SuppressionFixture.Send
        |> Ash.Changeset.for_create(:create_checked, %{
          subscriber_id: subscriber.id,
          org_id: org_id
        })
        |> Ash.create(authorize?: false)

      assert :ok =
               SendWorker.perform(
                 job(%{
                   "send_id" => send_row.id,
                   "org_id" => org_id,
                   "subscriber_id" => subscriber.id
                 })
               )

      reloaded = Ash.get!(SuppressionFixture.Send, send_row.id, authorize?: false)

      assert reloaded.status == :delivered
      assert is_binary(reloaded.provider_message_id) and reloaded.provider_message_id != "",
             "expected a real provider_message_id on the delivery record, got #{inspect(reloaded.provider_message_id)}"

      # It genuinely came from the provider's receipt (anti-tautology: not a
      # constant/placeholder value) — FakeProvider mints `fake_msg_<n>`.
      assert String.starts_with?(reloaded.provider_message_id, "fake_msg_")
    end
  end
end
