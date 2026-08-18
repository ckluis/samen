# Fixture data for the harness NON-VACUITY self-test
# (test/delivery_provider_conformance_case_test.exs). Proves the shared
# Samen.Delivery.ProviderConformanceCase harness works end-to-end against a
# throwaway adapter completely independent of samen_postmark — so a harness
# bug is caught here, not only when samen_postmark happens to exercise it.

alias Samen.Webhook.Signer

secret = "toy-secret-xyz-0123456789abcdef"
ts = System.os_time(:second)

valid_event_body =
  Jason.encode!(%{
    "id" => "evt_toy_1",
    "kind" => "delivered",
    "message_id" => "toy-msg-1",
    "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
    "email" => "toy-pii@example.test",
    "name" => "Toy Pii Name",
    "amount" => 42
  })

valid_sig = Signer.sign(valid_event_body, ts, secret)
tampered_sig = Signer.sign(valid_event_body, ts, "wrong-secret-does-not-match")

inbound_body =
  Jason.encode!(%{
    "message_id" => "toy-in-1",
    "from" => "sender@example.test",
    "subject" => "hello from the toy fixture",
    "text_body" => "hi there"
  })

inbound_sig = Signer.sign(inbound_body, ts, secret)

%{
  configured_config: %{secret: secret},
  message: %{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil},
  webhook: %{
    valid: %{body: valid_event_body, headers: [{"toy-signature", valid_sig}]},
    tampered: %{body: valid_event_body, headers: [{"toy-signature", tampered_sig}]}
  },
  inbound: %{body: inbound_body, headers: [{"toy-signature", inbound_sig}]},
  redaction: %{
    payload: %{"email" => "toy-pii@example.test", "name" => "Toy Pii Name", "amount" => 42},
    pii_strings: ["toy-pii@example.test", "Toy Pii Name"],
    retained_keys: ["amount"]
  },
  # DELIVER LEAK GATE (ADR-038 §4.5(f) / C3 T29, INV-1) — the ToyProvider routes a
  # clean, already-resolved request through the capture transport; no vt_, no PII.
  deliver_leak_probe: %{
    build_config: fn capture -> %{secret: secret, transport: capture} end,
    message: %{
      send_id: "s1",
      org_id: "o1",
      to_subscriber_id: "vt_probe_toy_token_must_not_reach_esp",
      template_id: nil
    },
    forbidden_plaintext: "ROGUE-TOY-SENTINEL@leak.test"
  }
}
