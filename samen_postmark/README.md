# samen_postmark

Postmark implementation of `Samen.Delivery.Provider` (ADR-038 §4) — the first-party-but-separate
adapter package (ADR-038 §8.1), and the **inbound-capable reference adapter** (serves C5/T59
later). Path-deps on `samen_core` ONLY (never `samen_web`); owns its own HTTP client dep (`req`,
pinned per ADR-038 §8.2).

## Status: C1 (T27)

- `configured?/1` requires `server_token` + `from` (sender address) — both, or `:not_configured`.
- `deliver/2` — real HTTP request-building/response-parsing against Postmark's send-email API,
  but genuinely `{:error, :not_implemented}` in production today: resolving a token-only
  `to_subscriber_id` to a plaintext email needs a host-specific vault reveal
  (`config[:resolve_recipient]`, an operator-wiring seam parallel to `Smtp`/`Api`'s standing
  "operator TODO"). The conformance/fixture suite supplies `:resolve_recipient` +
  `:transport` to prove the rest of the pipeline hermetically (no network).
- `verify_and_parse_event/3` / `parse_inbound/3` — FULLY implemented (no host glue needed): real
  HTTP Basic Auth verification (Postmark's actual webhook/inbound security model — it does not
  sign webhook bodies) + normalization into `Samen.Delivery.ProviderEvent` /
  `Samen.Delivery.InboundMessage`, with `redact_payload/1` stripping PII before any envelope
  would be persisted.
- Runs the SHARED `Samen.Delivery.ProviderConformanceCase` (samen_core) unchanged
  (`test/conformance_test.exs`).

## Running the tests

Standalone, no other samen app required:

```
cd samen_postmark
mix deps.get
mix test
```

## The `POSTMARK_API_TEST` no-credential smoke lane (ADR-038 §7.4)

Postmark's real API accepts the public literal server token `POSTMARK_API_TEST`: requests
validate and return success, and nothing is delivered. This is a real-HTTP reachability lane —
NOT part of `mix test` (lane 0 stays network-free) — gated by an env var so an offline machine
never flakes it:

```
SAMEN_POSTMARK_SMOKE=1 mix samen.smoke.postmark
```

Prints exactly one of:

- `POSTMARK-SMOKE: PASSED` (exit 0) — real round-trip to `api.postmarkapp.com` succeeded.
- `POSTMARK-SMOKE: SKIPPED (offline: <reason>)` (exit 0) — no network reachable; an HONEST skip,
  never claimed as coverage.
- `POSTMARK-SMOKE: FAILED (<reason>)` (exit 1) — reachable but the adapter's request/response
  handling is wrong.

## The `SAMEN_ESP_LIVE=1` live-smoke lane (ADR-038 §7.1 lane 2, documented, not implemented here)

A REAL send to a sink address with real provider credentials is a separate, heavier lane
(`SAMEN_ESP_LIVE=1` + real `server_token`/`from`/sink recipient) that actually delivers mail —
out of C1 scope (no task in this phase wires it; a future phase gate may add a tagged
integration test gated on this env var, per ADR-038 §7.1). Never run in `ci.sh`/`ci-fast.sh`.

## Wiring

`samen_core` never references this package (INV-4). A host selects it via config:

```elixir
config :samen_core, :delivery_provider,
  {SamenPostmark.Provider,
   %{
     server_token: System.get_env("POSTMARK_SERVER_TOKEN"),
     from: "notifications@yourdomain.com",
     webhook_username: System.get_env("POSTMARK_WEBHOOK_USER"),
     webhook_password: System.get_env("POSTMARK_WEBHOOK_PASS"),
     inbound_username: System.get_env("POSTMARK_INBOUND_USER"),
     inbound_password: System.get_env("POSTMARK_INBOUND_PASS"),
     resolve_recipient: &MyHost.Delivery.resolve_recipient/1
   }}
```

`resolve_recipient` is the operator-wiring seam: an arity-1 function
`Samen.Delivery.Message.t() -> {:ok, email} | {:error, reason}` that performs the host's own
governed vault reveal. Until wired, `deliver/2` stays honestly `{:error, :not_implemented}`.
