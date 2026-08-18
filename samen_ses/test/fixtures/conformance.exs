# Checked-in, hand-curated conformance fixture (ADR-038 §7.2 — never
# network-recorded in CI). Consumed by
# Samen.Delivery.ProviderConformanceCase (samen_core) via
# `use Samen.Delivery.ProviderConformanceCase, fixtures: "test/fixtures", ...`.
#
# Unlike samen_postmark's Basic-Auth fixture, SES/SNS webhook verification is
# a REAL RSA signature over a canonical string (SamenSes.SnsSignature) —
# proving it hermetically means generating a THROWAWAY keypair/cert IN THIS
# FILE (via :public_key.pkix_test_data/1, Erlang/OTP's own test-cert
# generator) and signing the fixture body with the real production
# canonical-string builder (SamenSes.SnsSignature.canonical_string/1), so
# `mix test` proves the REAL RSA verify code path end-to-end without ever
# touching the network — the ephemeral cert is handed back through the
# fixture's injectable `cert_fetcher` (ADR-038 §7.2).

alias SamenSes.SnsSignature

test_certs =
  %{
    root: [{:key, {:rsa, 2048, 65537}}],
    intermediates: [],
    peer: [{:key, {:rsa, 2048, 65537}}]
  }
  |> :public_key.pkix_test_data()
  |> Map.new()

{:RSAPrivateKey, key_der} = test_certs.key
fixture_private_key = :public_key.der_decode(:RSAPrivateKey, key_der)
fixture_cert_pem = :public_key.pem_encode([{:Certificate, test_certs.cert, :not_encrypted}])

signing_cert_url = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-fixture.pem"

bounce_pii_email = "bounced-person@example.test"
bounce_pii_name = "Bounced Person"

inner_bounce_json =
  Jason.encode!(%{
    "eventType" => "Bounce",
    "bounce" => %{
      "bounceType" => "Permanent",
      "bounceSubType" => "General",
      "bouncedRecipients" => [
        %{
          "emailAddress" => bounce_pii_email,
          "status" => "5.1.1",
          "diagnosticCode" => "smtp; 550 5.1.1 no such user"
        }
      ],
      "timestamp" => "2026-07-22T00:00:00.000Z",
      "feedbackId" => "fixture-feedback-id-1"
    },
    "mail" => %{
      "timestamp" => "2026-07-21T23:59:00.000Z",
      "source" => "sender@example.test",
      "messageId" => "fixture-ses-bounce-msg-id-abc",
      "destination" => [bounce_pii_email],
      "commonHeaders" => %{
        "from" => ["sender@example.test"],
        "to" => [bounce_pii_email],
        "subject" => "Welcome to samen!"
      },
      "sourceIp" => "203.0.113.5",
      "callerIdentity" => bounce_pii_name
    }
  })

notification_envelope = %{
  "Type" => "Notification",
  "MessageId" => "fixture-sns-message-id-notif-1",
  "TopicArn" => "arn:aws:sns:us-east-1:123456789012:fixture-ses-events",
  "Subject" => "Amazon SES Email Event Notification",
  "Message" => inner_bounce_json,
  "Timestamp" => "2026-07-22T00:00:01.000Z",
  "SignatureVersion" => "1",
  "SigningCertURL" => signing_cert_url,
  "UnsubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe&SubscriptionArn=fixture"
}

signable = SnsSignature.canonical_string(notification_envelope)
raw_signature = :public_key.sign(signable, :sha, fixture_private_key)

valid_envelope = Map.put(notification_envelope, "Signature", Base.encode64(raw_signature))
valid_body = Jason.encode!(valid_envelope)

# Tampered: same body, Signature's raw bytes flipped (last byte XOR 0xFF) —
# still valid base64 (decodes fine) but cryptographically wrong, so
# verification must fail closed (never a crash, never a false accept).
tampered_raw_signature =
  raw_signature
  |> :binary.bin_to_list()
  |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF))
  |> :binary.list_to_bin()

tampered_envelope = Map.put(notification_envelope, "Signature", Base.encode64(tampered_raw_signature))
tampered_body = Jason.encode!(tampered_envelope)

%{
  configured_config: %{
    access_key_id: "AKIA_FIXTURE",
    secret_access_key: "fixture-secret",
    region: "us-east-1",
    from: "sender@example.test",
    # Fixture-only DI (§7.2): keeps deliver/2 fully hermetic (no network)
    # while proving the REAL request/response handling path.
    resolve_recipient: fn _message -> {:ok, "recipient@example.test"} end,
    transport: fn _request ->
      {:ok, %{status: 200, body: %{"MessageId" => "fixture-deliver-msg-id-123"}}}
    end,
    # Fixture-only DI: hands back the in-memory ephemeral test cert for ANY
    # SigningCertURL, keeping verify_and_parse_event/3 hermetic while proving
    # the REAL RSA verify + canonical-string code path.
    cert_fetcher: fn _url -> {:ok, fixture_cert_pem} end,
    confirm_subscription: fn _url -> {:ok, "confirmed"} end
  },
  message: %{
    send_id: "11111111-1111-1111-1111-111111111111",
    org_id: "22222222-2222-2222-2222-222222222222",
    to_subscriber_id: "33333333-3333-3333-3333-333333333333",
    template_id: nil
  },
  webhook: %{
    valid: %{body: valid_body, headers: []},
    tampered: %{body: tampered_body, headers: []}
  },
  # No `inbound:` key — :inbound is NOT a declared capability (ADR-038 §4.5
  # adapter split: "samen_ses ... no inbound"); the harness's
  # `fixture_binary/2` helper defaults gracefully to "{}" when the key is
  # absent, matching the "REQUIRED only if :inbound is in the declared
  # capabilities" doc on the harness itself.
  redaction: %{
    payload: Jason.decode!(inner_bounce_json),
    pii_strings: [bounce_pii_email, bounce_pii_name],
    retained_keys: ["eventType"]
  },
  # DELIVER LEAK GATE (ADR-038 §4.5(f) / C3 T29, INV-1). The harness runs
  # deliver/2 with `transport` swapped for its capture fn and asserts the
  # outbound SES request carries no vt_ token and not the forbidden
  # sentinel. `to_subscriber_id` is a vt_-shaped token: a conformant adapter
  # (which addresses from the resolved recipient, never the raw token) is
  # PROVEN not to forward it to the ESP.
  deliver_leak_probe: %{
    build_config: fn capture ->
      %{
        access_key_id: "AKIA_FIXTURE",
        secret_access_key: "fixture-secret",
        region: "us-east-1",
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
