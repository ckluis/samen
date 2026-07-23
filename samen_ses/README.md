# samen_ses

AWS SES implementation of `Samen.Delivery.Provider` (ADR-038 §4) — the first-party-but-separate
adapter package (ADR-038 §8.1), and the **SECOND reference ESP adapter** (M1 ruling), slotting
into the SAME shared machinery `samen_postmark` (T27) built — the
`Samen.Delivery.ProviderConformanceCase` harness and the T30 deliverability pipeline — without
editing either. Path-deps on `samen_core` ONLY (never `samen_web`); owns its own HTTP client
(`req`) and AWS SigV4 signing dep (`aws_signature`, ADR-038 §8.2).

## Status: C1 (T94)

- `configured?/1` requires `access_key_id` + `secret_access_key` + `region` + `from` — all four,
  or `:not_configured`.
- `deliver/2` — real SigV4-signed HTTP request-building/response-parsing against SES's `SendEmail`
  v2 REST API, but genuinely `{:error, :not_implemented}` in production today: resolving a
  token-only `to_subscriber_id` to a plaintext email needs a host-specific vault reveal
  (`config[:resolve_recipient]`, an operator-wiring seam parallel to `samen_postmark`/`Smtp`/
  `Api`'s standing "operator TODO"). The conformance/fixture suite supplies `:resolve_recipient` +
  `:transport` to prove the rest of the pipeline hermetically (no network).
- `verify_and_parse_event/3` — FULLY implemented, no host glue needed: real SNS envelope RSA
  signature verification (`SamenSes.SnsSignature`, PKCS#1 v1.5 over the AWS canonical string,
  verified against the X.509 cert served at the envelope's own `SigningCertURL`), the SNS
  subscription-confirmation handshake, and normalization of SES `Bounce`/`Complaint`/`Delivery`/
  `Open`/`Click` events into `Samen.Delivery.ProviderEvent`, with `redact_payload/1` stripping PII
  before any envelope would be persisted.
- **NOT inbound-capable** (ADR-038 §4.5 adapter split) — `parse_inbound/3` stays the honest
  `use Samen.Delivery.Provider` default (`{:error, :not_implemented}`), never overridden.
- Runs the SHARED `Samen.Delivery.ProviderConformanceCase` (samen_core, T27) unchanged
  (`test/conformance_test.exs`), including the §4.5(f) deliver-no-leak gate.

## Why AWS SNS webhook verification differs from Postmark's

Postmark signs nothing — its webhook/inbound security model is HTTP Basic Auth on the URL.
SES publishes bounce/complaint/delivery/open/click notifications through **SNS**: every webhook
body is an SNS envelope carrying its OWN per-message RSA signature (base64, PKCS#1 v1.5, SHA-1 for
`SignatureVersion "1"` / SHA-256 for `"2"`) computed over a canonical string built from specific
envelope fields, verifiable against the certificate published at the envelope's own
`SigningCertURL`. `SamenSes.SnsSignature` implements this for real:

- `canonical_string/1` — the binding, AWS-documented field order (different for `Notification` vs
  `SubscriptionConfirmation`/`UnsubscribeConfirmation`).
- `verify/2` — decodes the base64 signature, fetches the cert (via an injectable `cert_fetcher`),
  extracts its RSA public key, and calls `:public_key.verify/4`. Fails closed
  (`{:error, :invalid_signature}`) on ANY malformed/missing field — never raises on
  attacker-controlled input.
- `valid_sns_host?/1` — the SSRF guard: `SigningCertURL`/`SubscribeURL` are attacker-controlled
  fields inside an unverified envelope; the real fetcher refuses anything that is not a genuine
  `sns.<region>.amazonaws.com`(`.cn`)? hostname before issuing the request.
- The SNS **subscription-confirmation handshake** lives inside `verify_and_parse_event/3`: once a
  `Type == "SubscriptionConfirmation"` envelope's OWN signature verifies, its `SubscribeURL` is
  GET-ed (`SamenSes.SnsSignature.fetch_live/1` by default, injectable via
  `config[:confirm_subscription]`) to complete the AWS handshake; the call returns an `:unhandled`
  `ProviderEvent` either way (a handshake hiccup never turns an otherwise-valid envelope into a
  retried error — SNS will not resend it).

Hermeticity (ADR-038 §7.2, mirrors `samen_postmark`'s `:transport` injection): real cert
verification needs the PEM served at `SigningCertURL`, so `config[:cert_fetcher]` is an
injectable `(url -> {:ok, pem} | {:error, term()})` hook. `mix test` never touches the network —
the conformance/fixture suite generates an EPHEMERAL self-signed test certificate in-memory via
`:public_key.pkix_test_data/1`, signs the fixture envelope with its private key for real, and
hands the fixture cert back through `cert_fetcher` — proving the REAL RSA verify + canonical-string
code path end to end without any network access.

## Redaction — allowlist from the start

`redact_payload/1` ships as a top-level scalar-key ALLOWLIST (`@safe_keys` in
`lib/samen_ses/provider.ex`) — never a denylist, and never retrofitted like `samen_postmark`/
`samen_stripe` had to be (T24/T30). A real SES event (the inner `Message` JSON of an SNS
`Notification`) is deeply nested by vendor design — every PII-bearing field (recipient addresses,
headers, `mail.source`) lives under `bounce`/`complaint`/`delivery`/`mail`, all non-scalar — so a
top-level-only allowlist retains only the genuinely top-level scalar fields (`eventType`, its
legacy alias `notificationType`, `Type`) and drops everything nested WHOLESALE, including any
invented/unenumerated field. `test/provider_test.exs` proves this with a red (an unenumerated
nested PII field never survives) + control (a whitelisted top-level field does) pair.

## SES-specific deliverability (handoff done-criterion 2)

`test/deliverability_test.exs` proves the ADAPTER-side half of C4: real SNS-wrapped `Bounce`/
`Complaint` (and `Delivery`/`Open`/`Click`) fixtures parse to the correctly-kinded, correctly-
redacted `Samen.Delivery.ProviderEvent`, with `provider_message_id` extracted from
`mail.messageId`. `samen_core` is vendor-free (INV-4) and therefore cannot depend on this package,
so — exactly as `samen_postmark`/T27 established — the DOMAIN-side half (matching a
`ProviderEvent` to a send receipt, writing `Samen.Delivery.EmailEvent`/`Samen.Delivery.Suppression`)
is proven ONCE, generically, in `samen_core/test/delivery/deliverability_test.exs` against a
hand-built `ProviderEvent`: since `ProviderEvent` is provider-agnostic (a `provider: atom` label
plus `kind`/`provider_message_id`/`payload`), the SAME `Samen.Delivery.Deliverability.handle_event/2`
logic that test proves for a `:postmark`-labeled event applies verbatim to the `:ses`-labeled
events this adapter produces — this file proves this adapter produces that exact shape for real
SES/SNS fixture bodies. Together the two files prove the full pipeline for SES, without this
package building a second, parallel EmailEvent/Suppression pipeline (scope discipline).

## Running the tests

Standalone, no other samen app required:

```
cd samen_ses
mix deps.get
mix test
```

## The `SAMEN_ESP_LIVE=1` live-smoke lane (ADR-038 §7.1 lane 2)

SES has no public no-credential test token (unlike Postmark's `POSTMARK_API_TEST`, §7.4) — a real
smoke send needs real AWS creds and a verified sender:

```
SAMEN_ESP_LIVE=1 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_REGION=us-east-1 \
SAMEN_SES_SMOKE_FROM=verified-sender@yourdomain.com \
SAMEN_SES_SMOKE_TO=verified-sink@yourdomain.com \
mix samen.smoke.ses
```

Prints exactly one of:

- `SES-SMOKE: PASSED (MessageId=...)` (exit 0) — a real `SendEmail` round-trip succeeded.
- `SES-SMOKE: SKIPPED (...)` (exit 0) — gate off, required env missing, or offline; an HONEST
  skip, never claimed as coverage.
- `SES-SMOKE: FAILED (...)` (exit 1) — reachable but the request/response handling is wrong, or
  SES rejected the send.

Never run in `ci.sh`/`ci-fast.sh`.

## Wiring

`samen_core` never references this package (INV-4). A host selects it via config:

```elixir
config :samen_core, :delivery_provider,
  {SamenSes.Provider,
   %{
     access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
     secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
     region: System.get_env("AWS_REGION"),
     from: "notifications@yourdomain.com",
     resolve_recipient: &MyHost.Delivery.resolve_recipient/1
   }}
```

`resolve_recipient` is the operator-wiring seam: an arity-1 function
`Samen.Delivery.Message.t() -> {:ok, email} | {:error, reason}` that performs the host's own
governed vault reveal. Until wired, `deliver/2` stays honestly `{:error, :not_implemented}`.

The SNS webhook endpoint (mounted by `samen_web`'s `POST /webhooks/:provider` ingress, T19) is
configured to dispatch to `SamenSes.Provider.verify_and_parse_event/3` with the SAME config map —
no separate credential story for inbound webhooks (SNS verification needs no AWS creds at all,
only the `cert_fetcher`/`confirm_subscription` seams, which default to real HTTPS fetches).

## Host wiring is deferred

No real host in this repo (`demo`/`driftwood`/`pawchart`) is wired to use `samen_ses` — per the
T94 handoff scope, host-wiring is out of scope for this task.
