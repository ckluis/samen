# samen_stripe

Stripe implementation of `Samen.Billing.Provider` (ADR-038 §3) — a first-party-but-separate
adapter package (ADR-038 §8.1). Path-deps on `samen_core` ONLY (never `samen_web`); owns its
own HTTP client dep (`req`, pinned per ADR-038 §8.2).

## Status: B1 skeleton (T18)

Every callback in `SamenStripe.Provider` is present and fail-honest:

- `configured?/1` is `true` only when `config[:secret_key]` is present and non-empty.
- Every other callback (except `redact_payload/1`) returns `{:error, :not_configured}` when
  unconfigured, and `{:error, :not_implemented}` when configured but not yet wired to a real
  Stripe HTTP call — never a fake `{:ok, _}` (ADR-014/ADR-038 fail-honest contract).
- `redact_payload/1` is pure and does real work now (strips known PII-bearing keys before a
  webhook envelope is persisted); it does not need credentials.

Real HTTP dispatch (checkout, portal, lifecycle mutations, usage reporting, convergence
fetch) and Stripe webhook signature verification are follow-up work (ADR-038 T19–T21) — NOT
implemented here.

## Running the tests

Standalone, no other samen app required:

```
cd samen_stripe
mix deps.get
mix test
```

## Wiring

`samen_core` never references this package (INV-4). A host selects it via config:

```elixir
config :samen_core, :billing_provider, {SamenStripe.Provider, %{secret_key: "sk_..."}}
```
