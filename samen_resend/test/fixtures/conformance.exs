# Checked-in, hand-curated conformance fixture (ADR-038 §7.2 — never
# network-recorded in CI). Consumed by
# Samen.Delivery.ProviderConformanceCase (samen_core) via
# `use Samen.Delivery.ProviderConformanceCase, fixtures: "test/fixtures", ...`.
#
# Unlike samen_postmark's Basic-Auth-on-the-URL model, Resend webhook
# verification is a REAL Svix-style HMAC-SHA256 signature over
# "{svix-id}.{svix-timestamp}.{body}" (SamenResend.SvixSignature) — proving
# it hermetically means computing the real signature over this fixture's
# body IN THIS FILE, with the svix-timestamp generated fresh at
# `Code.eval_file` time (this .exs is re-evaluated on every `mix test` run),
# so the timestamp-tolerance replay check always sees a genuinely fresh
# timestamp with zero network access.

# A base64-encoded fixture secret in Resend/Svix's own `whsec_<base64>`
# shape — `SvixSignature.verify/4` strips the prefix and base64-decodes the
# remainder to get the raw HMAC key.
fixture_secret = "whsec_" <> Base.encode64("fixture-resend-webhook-signing-secret-32b")

bounce_pii_email = "bounced-person@example.test"
bounce_pii_subject = "Welcome, Jane Doe!"

bounce_body =
  Jason.encode!(%{
    "type" => "email.bounced",
    "created_at" => "2026-07-22T00:00:00.000Z",
    "data" => %{
      "created_at" => "2026-07-22T00:00:00.000Z",
      "email_id" => "fixture-resend-bounce-msg-id-abc",
      "from" => "sender@example.test",
      "to" => [bounce_pii_email],
      "subject" => bounce_pii_subject,
      "bounce" => %{"type" => "Permanent", "message" => "smtp; 550 5.1.1 no such user"}
    }
  })

svix_id = "msg_fixture_bounce_1"
svix_timestamp = System.system_time(:second) |> Integer.to_string()

signed_content = svix_id <> "." <> svix_timestamp <> "." <> bounce_body
{:ok, hmac_key} = fixture_secret |> String.trim_leading("whsec_") |> Base.decode64()
raw_signature = :crypto.mac(:hmac, :sha256, hmac_key, signed_content)
valid_signature_header = "v1," <> Base.encode64(raw_signature)

valid_headers = [
  {"svix-id", svix_id},
  {"svix-timestamp", svix_timestamp},
  {"svix-signature", valid_signature_header}
]

# Tampered: same body, same id/timestamp, Signature's raw bytes flipped
# (last byte XOR 0xFF) — still valid base64 (decodes fine) but
# cryptographically wrong, so verification must fail closed (never a crash,
# never a false accept).
tampered_raw_signature =
  raw_signature
  |> :binary.bin_to_list()
  |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF))
  |> :binary.list_to_bin()

tampered_headers = [
  {"svix-id", svix_id},
  {"svix-timestamp", svix_timestamp},
  {"svix-signature", "v1," <> Base.encode64(tampered_raw_signature)}
]

%{
  configured_config: %{
    api_key: "fixture-api-key",
    from: "sender@example.test",
    webhook_secret: fixture_secret,
    # Fixture-only DI (§7.2): keeps deliver/2 fully hermetic (no network)
    # while proving the REAL request/response handling path.
    resolve_recipient: fn _message -> {:ok, "recipient@example.test"} end,
    transport: fn _request ->
      {:ok, %{status: 200, body: %{"id" => "fixture-deliver-msg-id-123"}}}
    end
  },
  message: %{
    send_id: "11111111-1111-1111-1111-111111111111",
    org_id: "22222222-2222-2222-2222-222222222222",
    to_subscriber_id: "33333333-3333-3333-3333-333333333333",
    template_id: nil
  },
  webhook: %{
    valid: %{body: bounce_body, headers: valid_headers},
    tampered: %{body: bounce_body, headers: tampered_headers}
  },
  # No `inbound:` key — :inbound is NOT a declared capability (ADR-038 §4.5
  # adapter split: "samen_resend ... no inbound"); the harness's
  # `fixture_binary/2` helper defaults gracefully to "{}" when the key is
  # absent, matching the "REQUIRED only if :inbound is in the declared
  # capabilities" doc on the harness itself.
  redaction: %{
    payload: Jason.decode!(bounce_body),
    pii_strings: [bounce_pii_email, bounce_pii_subject],
    retained_keys: ["type"]
  },
  # DELIVER LEAK GATE (ADR-038 §4.5(f) / C3 T29, INV-1). The harness runs
  # deliver/2 with `transport` swapped for its capture fn and asserts the
  # outbound Resend request carries no vt_ token and not the forbidden
  # sentinel. `to_subscriber_id` is a vt_-shaped token: a conformant adapter
  # (which addresses from the resolved recipient, never the raw token) is
  # PROVEN not to forward it to the ESP.
  deliver_leak_probe: %{
    build_config: fn capture ->
      %{
        api_key: "fixture-api-key",
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
