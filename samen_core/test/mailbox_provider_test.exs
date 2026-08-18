defmodule Samen.MailboxProviderTest do
  @moduledoc """
  T74 (spec §I1) — the MAILBOX SEAM's fail-honest contract, pure-logic layer.

  The DB-backed full loop (fake provider → CRM Person/Company timelines, both
  directions, vaulted bodies, the MaskingCase 3-proof) lives in
  `samen_web/test/samen/web/mailbox_sync_test.exs` +
  `mailbox_timeline_masking_test.exs`, against the reference adopter host. This file
  pins what needs no database:

    * an UNCONFIGURED provider refuses EVERY callback with `{:error, :not_configured}`
      — never a canned `{:ok, _}` for work it did not do (ADR-014/024/026);
    * an UNDECLARED capability refuses with `{:error, :not_implemented}` regardless of
      configured state, and a DECLARED one really works (both directions checked);
    * `Samen.Mailbox.Sync`'s three operations refuse BEFORE any write when the config
      is unconfigured, and pass an adapter's own refusal through verbatim;
    * `provider_configured?/0` is `false` with no host flag set — the CI default —
      so no surface can render a fabricated "connected" state.
  """
  use ExUnit.Case, async: false

  alias Samen.Mailbox
  alias Samen.Mailbox.{Config, FakeProvider, Match, Message}

  # A config whose resources are deliberately bogus: if any operation touched the
  # database BEFORE the fail-honest gate, these would blow up instead of returning
  # a clean `{:error, :not_configured}` — that is the point.
  defp config(provider_config) do
    %Config{
      org_id: Ash.UUID.generate(),
      repo: NoSuchRepo,
      provider: FakeProvider,
      provider_config: provider_config,
      connection_resource: NoSuchConnection,
      message_resource: NoSuchMailMessage
    }
  end

  setup do
    FakeProvider.reset()
    on_exit(fn -> FakeProvider.reset() end)
    :ok
  end

  # ==========================================================================
  # The fail-honest contract — UNCONFIGURED refuses everything
  # ==========================================================================

  describe "unconfigured provider (the keyless CI default)" do
    test "configured?/1 is false for an empty config and for a non-map" do
      refute FakeProvider.configured?(%{})
      refute FakeProvider.configured?(nil)
    end

    test "EVERY network-touching callback returns {:error, :not_configured}" do
      FakeProvider.set_capabilities([:inbound_sync, :outbound_send, :push_notifications])

      assert {:error, :not_configured} = FakeProvider.connect(%{address: "a@ex.test"}, %{})
      assert {:error, :not_configured} = FakeProvider.disconnect("ref", %{})
      assert {:error, :not_configured} = FakeProvider.fetch("ref", nil, %{})
      assert {:error, :not_configured} = FakeProvider.send(%Message{}, "ref", %{})
      assert {:error, :not_configured} = FakeProvider.parse_push("{}", [], %{})
    end

    test "it records NO calls and returns NO fake data when unconfigured" do
      FakeProvider.set_capabilities([:inbound_sync])
      assert {:error, :not_configured} = FakeProvider.fetch("ref", nil, %{})
      assert FakeProvider.calls() == []
      assert FakeProvider.inbox() == []
    end

    test "redact_payload/1 stays pure + available (exempt from the gate) and PRUNES secrets" do
      redacted =
        FakeProvider.redact_payload(%{
          "refresh_token" => "r",
          :access_token => "tok",
          :body => "hello",
          :mailbox_id => "keep-me"
        })

      refute Map.has_key?(redacted, :access_token)
      refute Map.has_key?(redacted, "refresh_token")
      refute Map.has_key?(redacted, :body)
      assert redacted[:mailbox_id] == "keep-me"
    end
  end

  # ==========================================================================
  # Capability honesty — both directions
  # ==========================================================================

  describe "capability declaration is honest in BOTH directions" do
    test "an UNDECLARED capability refuses with :not_implemented even when CONFIGURED" do
      FakeProvider.set_capabilities([])

      assert {:error, :not_implemented} = FakeProvider.fetch("ref", nil, %{configured: true})
      assert {:error, :not_implemented} = FakeProvider.send(%Message{}, "ref", %{configured: true})
      assert {:error, :not_implemented} = FakeProvider.parse_push("{}", [], %{configured: true})
    end

    test "a DECLARED capability really works when configured (positive control)" do
      FakeProvider.set_capabilities([:inbound_sync, :outbound_send])

      assert {:ok, %{messages: [], cursor: "0"}} =
               FakeProvider.fetch("ref", nil, %{configured: true})

      assert {:ok, %{external_id: "fake_out" <> _}} =
               FakeProvider.send(%Message{subject: "hi"}, "ref", %{configured: true})
    end

    test "PRECEDENCE: unconfigured AND undeclared answers :not_implemented, not :not_configured" do
      # A PERMANENT absence must not be reported as a fixable one: `:not_configured`
      # says "wire credentials and this works", `:not_implemented` says "this adapter
      # will never do that". `capabilities/0` is therefore checked FIRST — the shipped
      # `Samen.Delivery.FakeProvider` precedent, and what the seam doc states.
      FakeProvider.set_capabilities([])

      assert {:error, :not_implemented} = FakeProvider.fetch("ref", nil, %{})
      assert {:error, :not_implemented} = FakeProvider.send(%Message{}, "ref", %{})
      assert {:error, :not_implemented} = FakeProvider.parse_push("{}", [], %{})

      # The NON-capability-gated callbacks (every mailbox provider connects) still
      # answer :not_configured — so this is a precedence rule, not a blanket override.
      assert {:error, :not_configured} = FakeProvider.connect(%{}, %{})
      assert {:error, :not_configured} = FakeProvider.disconnect("ref", %{})
    end

    test "`use Samen.Mailbox.Provider` injects fail-honest defaults for the optional callbacks" do
      defmodule MinimalProvider do
        @moduledoc false
        use Samen.Mailbox.Provider

        @impl true
        def configured?(config), do: Map.get(config, :configured) == true

        @impl true
        def connect(_params, _config), do: {:error, :not_configured}

        @impl true
        def fetch(_ref, _cursor, _config), do: {:error, :not_configured}

        @impl true
        def send(_message, _ref, _config), do: {:error, :not_configured}
      end

      assert MinimalProvider.capabilities() == []
      assert {:error, :not_implemented} = MinimalProvider.disconnect("ref", %{configured: true})
      assert {:error, :not_implemented} = MinimalProvider.parse_push("{}", [], %{configured: true})
      # The injected redact_payload is an honest identity pass-through, not a lie.
      assert MinimalProvider.redact_payload(%{a: 1}) == %{a: 1}
    end
  end

  # ==========================================================================
  # Samen.Mailbox.Config / Samen.Mailbox — the honest-empty-state predicates
  # ==========================================================================

  describe "configured?/1 — the single predicate the surfaces read" do
    test "a nil provider is NOT configured" do
      refute Config.configured?(%Config{
               org_id: "o",
               repo: NoSuchRepo,
               provider: nil,
               connection_resource: NoSuchConnection,
               message_resource: NoSuchMailMessage
             })
    end

    test "an un-credentialed provider is NOT configured; a credentialed one IS" do
      refute Config.configured?(config(%{}))
      assert Config.configured?(config(%{configured: true}))
    end

    test "provider_configured?/0 is FALSE with no host flag (the CI + un-wired-host default)" do
      previous = Application.get_env(:samen_core, :mailbox_provider)
      Application.delete_env(:samen_core, :mailbox_provider)
      on_exit(fn -> restore_env(previous) end)

      refute Mailbox.provider_configured?()
      assert Mailbox.provider_selection() == nil
    end

    test "provider_configured?/0 is TRUE only when the wired adapter says so (positive control)" do
      previous = Application.get_env(:samen_core, :mailbox_provider)
      on_exit(fn -> restore_env(previous) end)

      Application.put_env(:samen_core, :mailbox_provider, {FakeProvider, %{}})
      refute Mailbox.provider_configured?()

      Application.put_env(:samen_core, :mailbox_provider, {FakeProvider, %{configured: true}})
      assert Mailbox.provider_configured?()
    end
  end

  # ==========================================================================
  # Sync — refuses BEFORE any write, and passes adapter refusals through
  # ==========================================================================

  describe "Samen.Mailbox.Sync fail-honest" do
    test "connect/sync/send/disconnect all refuse with :not_configured and touch NO resource" do
      cfg = config(%{})
      connection = %{id: Ash.UUID.generate(), external_account_id: "ref", cursor: nil}

      assert {:error, :not_configured} = Mailbox.connect(%{user_id: Ash.UUID.generate()}, cfg)
      assert {:error, :not_configured} = Mailbox.sync(connection, cfg)
      assert {:error, :not_configured} = Mailbox.send(%{to: "a@ex.test"}, connection, cfg)
      assert {:error, :not_configured} = Mailbox.disconnect(connection, cfg)

      # Nothing reached the provider at all — no call recorded, no fake receipt minted.
      assert FakeProvider.calls() == []
      assert FakeProvider.sent() == []
    end

    test "a CONFIGURED provider that lacks the capability surfaces :not_implemented verbatim" do
      FakeProvider.set_capabilities([])
      cfg = config(%{configured: true})
      connection = %{id: Ash.UUID.generate(), external_account_id: "ref", cursor: nil}

      assert {:error, :not_implemented} = Mailbox.sync(connection, cfg)
      assert {:error, :not_implemented} = Mailbox.send(%{to: "a@ex.test"}, connection, cfg)
    end

    test "an unconfigured sync is NEVER reported as an empty success" do
      cfg = config(%{})
      connection = %{id: Ash.UUID.generate(), external_account_id: "ref", cursor: nil}

      result = Mailbox.sync(connection, cfg)
      refute match?({:ok, _}, result)
      assert result == {:error, :not_configured}
    end
  end

  # ==========================================================================
  # Normalization / matching primitives (no DB)
  # ==========================================================================

  describe "Match primitives" do
    test "normalize/1 trims, NFC-normalizes and downcases (BlindIndex parity)" do
      assert Match.normalize("  A@Ex.TEST ") == "a@ex.test"
      assert Match.normalize("a@ex.test") == Samen.Auth.BlindIndex.normalize("  A@Ex.TEST ")
      assert Match.normalize(nil) == nil
      assert Match.normalize(123) == nil
    end

    test "domain/1 extracts the normalized domain, nil when there is none" do
      assert Match.domain("Grace@Acme.TEST") == "acme.test"
      assert Match.domain("no-at-sign") == nil
      assert Match.domain(nil) == nil
    end

    test "thread_key/1 is a NON-REVERSIBLE digest, stable per thread, nil with no seed" do
      key = Match.thread_key(%Message{thread_id: "thr-1"})
      assert is_binary(key) and byte_size(key) == 64
      refute key =~ "thr-1"
      assert key == Match.thread_key(%Message{thread_id: "thr-1"})
      refute key == Match.thread_key(%Message{thread_id: "thr-2"})
      assert Match.thread_key(%Message{}) == nil
    end

    test "thread_key/1 falls back through thread_id ▸ in_reply_to ▸ references ▸ external_id" do
      assert Match.thread_key(%Message{in_reply_to: "<a@x>"}) ==
               Match.thread_key(%Message{thread_id: "<a@x>"})

      assert Match.thread_key(%Message{references: ["<root@x>"]}) ==
               Match.thread_key(%Message{thread_id: "<root@x>"})

      assert Match.thread_key(%Message{external_id: "ext-9"}) ==
               Match.thread_key(%Message{thread_id: "ext-9"})
    end
  end

  describe "Message.counterparty/1 — which side of the conversation the CRM matches on" do
    test "inbound matches the SENDER; outbound matches the first RECIPIENT" do
      assert Message.counterparty(%Message{direction: :inbound, from_address: "them@ex.test"}) ==
               "them@ex.test"

      assert Message.counterparty(%Message{
               direction: :outbound,
               from_address: "me@us.test",
               to_addresses: ["them@ex.test"]
             }) == "them@ex.test"
    end

    test "nil when the relevant side is missing (never a guess)" do
      assert Message.counterparty(%Message{direction: :inbound}) == nil
      assert Message.counterparty(%Message{direction: :outbound, to_addresses: []}) == nil
    end
  end

  defp restore_env(nil), do: Application.delete_env(:samen_core, :mailbox_provider)
  defp restore_env(value), do: Application.put_env(:samen_core, :mailbox_provider, value)
end
