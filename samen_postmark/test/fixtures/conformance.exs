# Checked-in, hand-curated conformance fixture (ADR-038 §7.2 — never
# network-recorded in CI). Consumed by
# Samen.AdapterConformanceCase (samen_core) via
# `load_fixtures!/1`, called from samen_postmark/test/conformance_test.exs.

bounce_pii_email = "bounced-person@example.test"
bounce_pii_name = "Bounced Person"

valid_bounce_body =
  Jason.encode!(%{
    "RecordType" => "Bounce",
    "ID" => 4_323_463,
    "Type" => "HardBounce",
    "TypeCode" => 1,
    "Name" => "Hard bounce",
    "Tag" => "welcome-email",
    "MessageID" => "fixture-bounce-msg-id-abc",
    "ServerID" => 1,
    "Description" => "The server was unable to deliver your mail to the destination.",
    "Details" => "smtp;550 5.1.1 The email account does not exist.",
    "Email" => bounce_pii_email,
    "From" => "sender@example.test",
    "FromName" => bounce_pii_name,
    "BouncedAt" => "2026-07-22T00:00:00.000-04:00",
    "DumpAvailable" => true,
    "Inactive" => true,
    "CanActivate" => true,
    "Subject" => "Welcome to samen!"
  })

# Postmark's real security model is HTTP Basic Auth on the webhook URL, not a
# body signature — "tampered" here means "wrong Authorization credentials",
# same body.
valid_webhook_headers = [
  {"authorization", "Basic " <> Base.encode64("wh_user:wh_pass")},
  {"content-type", "application/json"}
]

tampered_webhook_headers = [
  {"authorization", "Basic " <> Base.encode64("wh_user:definitely-the-wrong-password")},
  {"content-type", "application/json"}
]

inbound_body =
  Jason.encode!(%{
    "From" => "external-sender@example.test",
    "FromName" => "External Sender",
    "To" => "support@fixture-org.example.test",
    "Subject" => "Need help with my order",
    "MessageID" => "fixture-inbound-msg-id-xyz",
    "TextBody" => "Hi, I have a question about my order.",
    "HtmlBody" => "<p>Hi, I have a question about my order.</p>",
    "Headers" => [%{"Name" => "X-Spam-Score", "Value" => "0.1"}],
    "Attachments" => []
  })

inbound_headers = [
  {"authorization", "Basic " <> Base.encode64("in_user:in_pass")},
  {"content-type", "application/json"}
]

%{
  configured_config: %{
    server_token: "fixture-server-token",
    from: "sender@example.test",
    webhook_username: "wh_user",
    webhook_password: "wh_pass",
    inbound_username: "in_user",
    inbound_password: "in_pass",
    # Fixture-only DI (§7.2): keeps deliver/2 fully hermetic (no network) while
    # proving the REAL request/response handling path.
    resolve_recipient: fn _message -> {:ok, "recipient@example.test"} end,
    transport: fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "To" => "recipient@example.test",
           "SubmittedAt" => "2026-07-22T00:00:00.000-04:00",
           "MessageID" => "fixture-deliver-msg-id-123",
           "ErrorCode" => 0,
           "Message" => "OK"
         }
       }}
    end
  },
  message: %{
    send_id: "11111111-1111-1111-1111-111111111111",
    org_id: "22222222-2222-2222-2222-222222222222",
    to_subscriber_id: "33333333-3333-3333-3333-333333333333",
    template_id: nil
  },
  webhook: %{
    valid: %{body: valid_bounce_body, headers: valid_webhook_headers},
    tampered: %{body: valid_bounce_body, headers: tampered_webhook_headers}
  },
  inbound: %{body: inbound_body, headers: inbound_headers},
  redaction: %{
    payload: Jason.decode!(valid_bounce_body),
    pii_strings: [bounce_pii_email, bounce_pii_name],
    retained_keys: ["MessageID", "Type", "RecordType"]
  },
  # DELIVER LEAK GATE (ADR-038 §4.5(f) / C3 T29, INV-1). The harness runs deliver/2
  # with `transport` swapped for its capture fn and asserts the outbound Postmark
  # request carries no vt_ token and not the forbidden sentinel. `to_subscriber_id`
  # is a vt_-shaped token: a conformant adapter (which addresses from the resolved
  # recipient, never the raw token) is PROVEN not to forward it to the ESP.
  deliver_leak_probe: %{
    build_config: fn capture ->
      %{
        server_token: "fixture-server-token",
        from: "sender@example.test",
        resolve_recipient: fn _message -> {:ok, "recipient@example.test"} end,
        transport: capture
      }
    end,
    message: %{
      send_id: "11111111-1111-1111-1111-111111111111",
      org_id: "22222222-2222-2222-2222-222222222222",
      to_subscriber_id: "vt_probe_rogue_token_must_not_reach_esp",
      template_id: nil
    },
    forbidden_plaintext: "ROGUE-OTHER-SUBJECT-SENTINEL@leak.test"
  }
}
