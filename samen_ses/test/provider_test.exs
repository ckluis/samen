defmodule SamenSes.ProviderTest do
  @moduledoc """
  `SamenSes.Provider`-specific coverage beyond the shared conformance harness:
  the layered fail-honest gates, real SNS envelope dispatch
  (`SubscriptionConfirmation` handshake, `UnsubscribeConfirmation`, unknown
  `Type`), `SignatureVersion "2"` (SHA-256) support, the SSRF host guard, and
  the T94 allowlist-redaction red+control pair (ADR-038 §5.4 / INV-1).
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenSes.{Provider, SnsSignature}

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp base_config do
    %{access_key_id: "AKIA_X", secret_access_key: "secret", region: "us-east-1", from: "sender@example.test"}
  end

  # ---------------------------------------------------------------------------
  # Fixture cert/key helper (same recipe as test/fixtures/conformance.exs,
  # kept local rather than shared support code — matches samen_postmark's
  # single-file-per-concern test layout).

  defp gen_cert_and_key do
    test_certs =
      %{root: [{:key, {:rsa, 2048, 65537}}], intermediates: [], peer: [{:key, {:rsa, 2048, 65537}}]}
      |> :public_key.pkix_test_data()
      |> Map.new()

    {:RSAPrivateKey, key_der} = test_certs.key
    priv_key = :public_key.der_decode(:RSAPrivateKey, key_der)
    pem = :public_key.pem_encode([{:Certificate, test_certs.cert, :not_encrypted}])
    {priv_key, pem}
  end

  defp sign_envelope(envelope, priv_key, digest) do
    signable = SnsSignature.canonical_string(envelope)
    sig = :public_key.sign(signable, digest, priv_key)
    Map.put(envelope, "Signature", Base.encode64(sig))
  end

  defp flip_signature(envelope) do
    Map.update!(envelope, "Signature", fn sig ->
      raw = Base.decode64!(sig)

      flipped =
        raw
        |> :binary.bin_to_list()
        |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF))
        |> :binary.list_to_bin()

      Base.encode64(flipped)
    end)
  end

  defp cert_url, do: "https://sns.us-east-1.amazonaws.com/fixture-cert.pem"

  # ---------------------------------------------------------------------------
  # configured?/1

  describe "configured?/1" do
    test "false with none of the four required keys" do
      refute Provider.configured?(%{})
    end

    test "false missing any one of the four required keys" do
      base = base_config()

      for key <- Map.keys(base) do
        refute Provider.configured?(Map.delete(base, key)),
               "configured?/1 must be false when #{inspect(key)} is missing"
      end
    end

    test "true with all four present" do
      assert Provider.configured?(base_config())
    end
  end

  # ---------------------------------------------------------------------------
  # deliver/2 — layered fail-honest gates

  describe "deliver/2 fail-honest layering" do
    test "unconfigured (no creds) refuses :not_configured" do
      assert {:error, :not_configured} = Provider.deliver(msg(), %{})
    end

    test "configured but no :resolve_recipient wired refuses :not_implemented (operator TODO, never a fake ok)" do
      assert {:error, :not_implemented} = Provider.deliver(msg(), base_config())
    end

    test "resolve_recipient error is surfaced as-is" do
      config = Map.put(base_config(), :resolve_recipient, fn _ -> {:error, :vault_locked} end)
      assert {:error, :vault_locked} = Provider.deliver(msg(), config)
    end

    test "an invalid resolve_recipient result is surfaced honestly, never {:ok, _}" do
      config = Map.put(base_config(), :resolve_recipient, fn _ -> :bogus end)
      assert {:error, {:invalid_resolve_recipient_result, :bogus}} = Provider.deliver(msg(), config)
    end

    test "configured + resolve_recipient + transport genuinely dispatches (anti-tautology)" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn request ->
          assert request.to_email == "to@example.test"
          {:ok, %{status: 200, body: %{"MessageId" => "real-id-1"}}}
        end)

      assert {:ok, %{provider_message_id: "real-id-1"}} = Provider.deliver(msg(), config)
    end

    test "an SES-side error response is surfaced, never {:ok, _}" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req ->
          {:ok, %{status: 400, body: %{"message" => "Email address is not verified", "__type" => "MessageRejected"}}}
        end)

      assert {:error, {:ses_error, 400, "MessageRejected", "Email address is not verified"}} =
               Provider.deliver(msg(), config)
    end

    test "a transport-level failure (network) is surfaced, never {:ok, _}" do
      config =
        base_config()
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn _req -> {:error, :timeout} end)

      assert {:error, :timeout} = Provider.deliver(msg(), config)
    end

    test "session_token, when present, rides through to the outbound request" do
      config =
        base_config()
        |> Map.put(:session_token, "sts-token-1")
        |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
        |> Map.put(:transport, fn request ->
          assert request.session_token == "sts-token-1"
          {:ok, %{status: 200, body: %{"MessageId" => "id-1"}}}
        end)

      assert {:ok, _} = Provider.deliver(msg(), config)
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — the cheap layered gates (no crypto involved)

  describe "verify_and_parse_event/3 fail-honest layering" do
    test "unconfigured refuses :not_configured" do
      assert {:error, :not_configured} = Provider.verify_and_parse_event("{}", [], %{})
    end

    test "a malformed (non-JSON) body is :malformed" do
      assert {:error, :malformed} = Provider.verify_and_parse_event("not json", [], base_config())
    end

    test "valid JSON missing a Type field is :malformed" do
      body = Jason.encode!(%{"foo" => "bar"})
      assert {:error, :malformed} = Provider.verify_and_parse_event(body, [], base_config())
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — real SNS Notification signature verification

  describe "verify_and_parse_event/3 — real SNS Notification signature verification" do
    setup do
      {priv_key, pem} = gen_cert_and_key()
      config = Map.put(base_config(), :cert_fetcher, fn _url -> {:ok, pem} end)
      %{priv_key: priv_key, config: config}
    end

    defp bounce_envelope do
      inner =
        Jason.encode!(%{
          "eventType" => "Bounce",
          "bounce" => %{"bounceType" => "Permanent", "timestamp" => "2026-07-22T00:00:00.000Z"},
          "mail" => %{"messageId" => "ses-msg-1", "timestamp" => "2026-07-21T23:59:00.000Z"}
        })

      %{
        "Type" => "Notification",
        "MessageId" => "sns-msg-id-1",
        "TopicArn" => "arn:aws:sns:us-east-1:123456789012:t",
        "Message" => inner,
        "Timestamp" => "2026-07-22T00:00:01.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => cert_url()
      }
    end

    test "a validly-signed Bounce notification parses to :bounce", %{priv_key: priv_key, config: config} do
      signed = sign_envelope(bounce_envelope(), priv_key, :sha)

      assert {:ok, event} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
      assert event.kind == :bounce
      assert event.provider == :ses
      assert event.provider_message_id == "ses-msg-1"
      assert event.event_id == "sns-msg-id-1"
    end

    test "SignatureVersion 2 (SHA-256) is also supported", %{priv_key: priv_key, config: config} do
      envelope = Map.put(bounce_envelope(), "SignatureVersion", "2")
      signed = sign_envelope(envelope, priv_key, :sha256)

      assert {:ok, %{kind: :bounce}} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "an unsupported SignatureVersion refuses :invalid_signature (fail closed)", %{priv_key: priv_key, config: config} do
      envelope = Map.put(bounce_envelope(), "SignatureVersion", "3")
      signed = sign_envelope(envelope, priv_key, :sha)

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "RED: a tampered Signature is rejected, vs the CONTROL of the identical valid body", %{
      priv_key: priv_key,
      config: config
    } do
      signed = sign_envelope(bounce_envelope(), priv_key, :sha)

      # CONTROL — the real signature verifies.
      assert {:ok, _} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)

      # RED — same body, one byte of the signature flipped.
      tampered = flip_signature(signed)
      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(Jason.encode!(tampered), [], config)
    end

    test "the cert_fetcher failing to resolve refuses :invalid_signature (fail closed)", %{priv_key: priv_key} do
      signed = sign_envelope(bounce_envelope(), priv_key, :sha)
      config = Map.put(base_config(), :cert_fetcher, fn _url -> {:error, :offline} end)

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "an untrusted SigningCertURL refuses :invalid_signature — cert_fetcher is never even called", %{
      priv_key: priv_key
    } do
      envelope = Map.put(bounce_envelope(), "SigningCertURL", "https://evil.example.test/cert.pem")
      signed = sign_envelope(envelope, priv_key, :sha)

      config =
        Map.put(base_config(), :cert_fetcher, fn _url ->
          flunk("cert_fetcher must never be called for an untrusted SigningCertURL host")
        end)

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "unknown notification kinds map to :unhandled (stored replay-safe, not dispatched)", %{
      priv_key: priv_key,
      config: config
    } do
      inner = Jason.encode!(%{"eventType" => "RenderingFailure", "mail" => %{"messageId" => "m1"}})
      envelope = Map.put(bounce_envelope(), "Message", inner)
      signed = sign_envelope(envelope, priv_key, :sha)

      assert {:ok, %{kind: :unhandled}} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "a Notification whose inner Message is not valid JSON is :malformed (even after a valid envelope signature)",
         %{priv_key: priv_key, config: config} do
      envelope = Map.put(bounce_envelope(), "Message", "not actually json")
      signed = sign_envelope(envelope, priv_key, :sha)

      assert {:error, :malformed} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_parse_event/3 — the SNS subscription-confirmation handshake

  describe "verify_and_parse_event/3 — SubscriptionConfirmation handshake" do
    defp confirmation_envelope do
      %{
        "Type" => "SubscriptionConfirmation",
        "MessageId" => "sns-confirm-msg-1",
        "TopicArn" => "arn:aws:sns:us-east-1:123456789012:t",
        "Message" => "You have chosen to subscribe to the topic.",
        "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=fixture",
        "Token" => "fixture-token",
        "Timestamp" => "2026-07-22T00:00:01.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => cert_url()
      }
    end

    test "a validly-signed confirmation is confirmed (GET SubscribeURL) and parses to :unhandled" do
      {priv_key, pem} = gen_cert_and_key()
      test_pid = self()

      config =
        base_config()
        |> Map.put(:cert_fetcher, fn _url -> {:ok, pem} end)
        |> Map.put(:confirm_subscription, fn url ->
          send(test_pid, {:confirmed, url})
          {:ok, "ok"}
        end)

      signed = sign_envelope(confirmation_envelope(), priv_key, :sha)

      assert {:ok, %{kind: :unhandled, provider: :ses}} =
               Provider.verify_and_parse_event(Jason.encode!(signed), [], config)

      assert_received {:confirmed, "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=fixture"}
    end

    test "a confirm_subscription hook that raises never fails the (already signature-verified) parse" do
      {priv_key, pem} = gen_cert_and_key()

      config =
        base_config()
        |> Map.put(:cert_fetcher, fn _url -> {:ok, pem} end)
        |> Map.put(:confirm_subscription, fn _url -> raise "boom" end)

      signed = sign_envelope(confirmation_envelope(), priv_key, :sha)
      assert {:ok, %{kind: :unhandled}} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "an untrusted SubscribeURL is never GET-ed" do
      {priv_key, pem} = gen_cert_and_key()

      config =
        base_config()
        |> Map.put(:cert_fetcher, fn _url -> {:ok, pem} end)
        |> Map.put(:confirm_subscription, fn _url -> flunk("must never GET an untrusted SubscribeURL") end)

      envelope = Map.put(confirmation_envelope(), "SubscribeURL", "https://evil.example.test/confirm")
      signed = sign_envelope(envelope, priv_key, :sha)

      assert {:ok, %{kind: :unhandled}} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end

    test "a tampered confirmation signature is rejected and NEVER confirmed" do
      {priv_key, pem} = gen_cert_and_key()

      config =
        base_config()
        |> Map.put(:cert_fetcher, fn _url -> {:ok, pem} end)
        |> Map.put(:confirm_subscription, fn _url -> flunk("must never confirm on a tampered signature") end)

      signed = sign_envelope(confirmation_envelope(), priv_key, :sha)
      tampered = flip_signature(signed)

      assert {:error, :invalid_signature} = Provider.verify_and_parse_event(Jason.encode!(tampered), [], config)
    end
  end

  describe "verify_and_parse_event/3 — UnsubscribeConfirmation" do
    test "a validly-signed UnsubscribeConfirmation parses to :unhandled, no confirm attempted" do
      {priv_key, pem} = gen_cert_and_key()

      config =
        base_config()
        |> Map.put(:cert_fetcher, fn _url -> {:ok, pem} end)
        |> Map.put(:confirm_subscription, fn _url -> flunk("UnsubscribeConfirmation must never trigger a confirm GET") end)

      envelope = %{
        "Type" => "UnsubscribeConfirmation",
        "MessageId" => "sns-unsub-msg-1",
        "TopicArn" => "arn:aws:sns:us-east-1:123456789012:t",
        "Message" => "You have chosen to unsubscribe from the topic.",
        "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=fixture",
        "Token" => "fixture-token",
        "Timestamp" => "2026-07-22T00:00:01.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => cert_url()
      }

      signed = sign_envelope(envelope, priv_key, :sha)
      assert {:ok, %{kind: :unhandled}} = Provider.verify_and_parse_event(Jason.encode!(signed), [], config)
    end
  end

  # ---------------------------------------------------------------------------
  # SamenSes.SnsSignature.valid_sns_host?/1 — the SSRF guard, standalone

  describe "SnsSignature.valid_sns_host?/1" do
    test "RED: non-AWS / non-https / spoofed hosts are rejected" do
      refute SnsSignature.valid_sns_host?("https://evil.example.test/cert.pem")
      refute SnsSignature.valid_sns_host?("http://sns.us-east-1.amazonaws.com/cert.pem")
      refute SnsSignature.valid_sns_host?("https://sns.us-east-1.amazonaws.com.evil.test/cert.pem")
      refute SnsSignature.valid_sns_host?("https://evil.test/sns.us-east-1.amazonaws.com")
      refute SnsSignature.valid_sns_host?("not a url")
      refute SnsSignature.valid_sns_host?(nil)
    end

    test "CONTROL: a genuine sns.<region>.amazonaws.com(.cn)? https host is accepted" do
      assert SnsSignature.valid_sns_host?("https://sns.us-east-1.amazonaws.com/cert.pem")
      assert SnsSignature.valid_sns_host?("https://sns.cn-north-1.amazonaws.com.cn/cert.pem")
    end
  end

  # ---------------------------------------------------------------------------
  # capabilities/0 — no :inbound (ADR-038 §4.5 adapter split: "samen_ses ... no inbound")

  test "capabilities/0 declares deliverability_webhooks + tracking, NOT inbound" do
    assert Enum.sort(Provider.capabilities()) == Enum.sort([:deliverability_webhooks, :tracking])
  end

  test "parse_inbound/3 always refuses :not_implemented (undeclared capability, honest `use` default)" do
    assert {:error, :not_implemented} = Provider.parse_inbound("{}", [], base_config())
    assert {:error, :not_implemented} = Provider.parse_inbound("{}", [], %{})
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 — ships as an ALLOWLIST from the start (T94; mirrors the
  # T24/T30 denylist->allowlist hardening line samen_postmark/samen_stripe
  # had to retrofit — see the Provider moduledoc for why SES's deeply-nested
  # real payload shape makes the rule bind even harder here).

  describe "redact_payload/1" do
    test "strips a flat top-level PII field, retains a safe top-level field" do
      payload = %{"eventType" => "Bounce", "someTopLevelEmail" => "person@example.test"}
      redacted = Provider.redact_payload(payload)

      assert redacted["eventType"] == "Bounce"
      refute Map.has_key?(redacted, "someTopLevelEmail")
    end

    test "RED: PII under an unenumerated NESTED field never survives redaction (control: safe field survives)" do
      # `bounce`/`mail` are the REAL SES nested containers; `extraDebugInfo` is
      # an INVENTED field no allowlist enumerates — the same free-form-PII-
      # container risk `Metadata`/`metadata` posed for samen_postmark/
      # samen_stripe, just standing in for "any future/unknown nested field".
      novel_pii_ssn = "123-45-6789"

      payload = %{
        "eventType" => "Bounce",
        "bounce" => %{"bouncedRecipients" => [%{"emailAddress" => "leak@example.test"}]},
        "mail" => %{"destination" => ["leak2@example.test"]},
        "extraDebugInfo" => %{"customerSsn" => novel_pii_ssn}
      }

      redacted = Provider.redact_payload(payload)
      serialized = Jason.encode!(redacted)

      refute serialized =~ novel_pii_ssn,
             "PII under an unenumerated nested key must not survive redaction"

      refute serialized =~ "leak@example.test"
      refute serialized =~ "leak2@example.test"
      refute Map.has_key?(redacted, "bounce")
      refute Map.has_key?(redacted, "mail")
      refute Map.has_key?(redacted, "extraDebugInfo")

      # CONTROL: redaction is surgical, not a wipe — the safe top-level field survives.
      assert redacted["eventType"] == "Bounce"
    end

    test "an allowlisted key whose VALUE is a nested map is dropped too (not assumed safe by name)" do
      payload = %{
        "eventType" => %{"unexpected" => "nested-shape", "email" => "sneaky@example.test"},
        "Type" => "Notification"
      }

      redacted = Provider.redact_payload(payload)

      refute Map.has_key?(redacted, "eventType"),
             "an allowlisted key with a non-scalar value must still be dropped"

      assert redacted["Type"] == "Notification"
    end
  end
end
