defmodule Samen.Delivery.DeliverLeakGateTest do
  @moduledoc """
  C3 (T29) attempt-2 — the RED proof that the deliver leak gate
  (`Samen.Delivery.ProviderConformanceCase.assert_deliver_no_leak!/2`, ADR-038
  §4.5(f)) makes INV-1 masking enforced-by-a-gate on EVERY adapter rather than
  adapter goodwill.

  The gap attempt 1 left: `Chokepoint.send/2` calls `adapter.deliver/2` directly,
  so a rogue/careless adapter that ignores the `render_for_send`/`provider_payload`
  seam and forwards the raw token-only message (a `vt_` `to_subscriber_id`) or
  hand-reveals PII could leak to the ESP — the fail-closed payload guard only fires
  when an adapter VOLUNTARILY calls it. This test proves the leak is now CAUGHT at
  the conformance gate every adapter (incl. T94/T95) must pass:

    * RED — a `LeakyProvider` that forwards the raw `vt_` token AND a hand-revealed
      other-subject sentinel into its outbound request is CAUGHT (the gate flunks).
    * CONTROL (anti-tautology / RED-on-revert) — a `CleanProvider` that builds its
      outbound request ONLY from the framework's fail-closed
      `Samen.Delivery.RenderedEmail.provider_payload/1` PASSES the same gate, so the
      RED above is the leak firing, not a blanket refusal.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.{Message, Provider, ProviderConformanceCase, RenderedEmail}

  # A ROGUE adapter that BYPASSES the render seam: it forwards the raw token-only
  # message's `to_subscriber_id` (a vt_ token) and a hand-"revealed" other-subject
  # PII sentinel straight into its outbound ESP request — the exact goodwill-
  # dependent leak the P1 flagged.
  defmodule LeakyProvider do
    use Provider

    @impl true
    def configured?(config), do: is_function(Map.get(config, :transport), 1)

    @impl true
    def deliver(%Message{} = message, config) do
      request = %{
        # hand-revealed OTHER-subject PII (not the recipient's own address)
        "To" => "OTHER-SUBJECT-SENTINEL@leak.test",
        # the raw token-only message's vault reference forwarded to the ESP
        "X-Subscriber-Token" => message.to_subscriber_id
      }

      config.transport.(request)
      {:ok, %{provider_message_id: "leaky-1"}}
    end
  end

  # A CLEAN adapter: builds its outbound request ONLY from the framework's fail-
  # closed provider_payload (resolved recipient only, no vt_, no unresolved value).
  defmodule CleanProvider do
    use Provider

    @impl true
    def configured?(config), do: is_function(Map.get(config, :transport), 1)

    @impl true
    def deliver(%Message{} = message, config) do
      rendered = %RenderedEmail{
        send_id: message.send_id,
        to_subscriber_id: message.to_subscriber_id,
        template_ref: message.template_id,
        to: "recipient@example.test",
        subject: "Your account update",
        text_body: "hello recipient@example.test",
        html_body: "<p>hello recipient@example.test</p>",
        # the render KNOWS the vault token, but provider_payload never emits it
        vault_token_ref: message.to_subscriber_id
      }

      payload = RenderedEmail.provider_payload(rendered)

      config.transport.(%{
        "To" => payload.to,
        "Subject" => payload.subject,
        "TextBody" => payload.text_body,
        "HtmlBody" => payload.html_body
      })

      {:ok, %{provider_message_id: "clean-1"}}
    end
  end

  defp probe do
    %{
      deliver_leak_probe: %{
        build_config: fn capture -> %{transport: capture} end,
        message: %{
          send_id: "s1",
          org_id: "o1",
          to_subscriber_id: "vt_rogue_forwarded_token",
          template_id: nil
        },
        forbidden_plaintext: "OTHER-SUBJECT-SENTINEL@leak.test"
      }
    }
  end

  test "RED — the deliver leak gate CATCHES a rogue adapter (vt_ token + hand-revealed PII forwarded)" do
    assert_raise ExUnit.AssertionError, fn ->
      ProviderConformanceCase.assert_deliver_no_leak!(LeakyProvider, probe())
    end
  end

  test "CONTROL — a clean adapter building via provider_payload PASSES the SAME gate (RED is refutable)" do
    assert :ok == ProviderConformanceCase.assert_deliver_no_leak!(CleanProvider, probe())
  end

  test "the gate is NON-SKIPPABLE — a fixture missing deliver_leak_probe flunks" do
    assert_raise ExUnit.AssertionError, fn ->
      ProviderConformanceCase.assert_deliver_no_leak!(CleanProvider, %{})
    end
  end
end
