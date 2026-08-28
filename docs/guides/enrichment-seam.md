# Enrichment Seam — External Data Provider Adapter Contract

(spec §I8, T80; mirrors ADR-038 §4/§8 `Samen.Delivery.Provider` pattern)

## Overview

The enrichment seam lets a host connect external data sources (HR databases, enrichment APIs, data brokers) to enrich Person and Company records in Samen. The framework defines the contract; the host supplies a real adapter as a separate package behind an explicit config flag, never exercised in CI.

The seam is:
- **Honest** — unconfigured providers refuse with `{:error, :not_configured}`, never fake success.
- **PII-aware** — enriched personal data routes through `Samen.Pii.WriteGuard` + `Samen.Vault.Change` (hosted surface concern, not this contract).
- **Zero vendor coupling** — `samen_core` pulls no HTTP/SaaS dependency, no vendor module name.

## Configuration

```elixir
config :samen_core, :enrichment_provider, {MyEnrichmentAdapter.Provider, %{
  api_key: "...",
  endpoint: "https://api.example.com"
}}
```

If not configured, `Samen.Enrichment` returns `{:error, :not_configured}` on every enrich attempt.

## Behaviour: `Samen.Enrichment.Provider`

Every adapter must implement this behaviour. Use `use Samen.Enrichment.Provider` to inject fail-honest defaults for optional callbacks.

### `configured?(config :: map()) :: boolean()`

**Must implement.** Returns `true` when the provider has everything it needs (API key, endpoint, credentials), `false` otherwise. This is the single source of truth for the fail-honest gate — every other callback checks it first.

**Example:**

```elixir
@impl true
def configured?(config) do
  Map.has_key?(config, :api_key) and Map.get(config, :endpoint) != nil
end
```

### `capabilities() :: [capability()]`

**Optional** (defaults to `[]`). Returns an honestly-declared list of capabilities the adapter supports:
- `:person_enrich` — can enrich a Person
- `:company_enrich` — can enrich a Company

This is NOT config-dependent — it is a property of the adapter module itself.

**Example:**

```elixir
@impl true
def capabilities, do: [:person_enrich, :company_enrich]
```

### `enrich(subject_type :: :person | :company, subject_id :: any(), config :: map()) :: {:ok, map()} | {:error, term()}`

**Must implement.** Fetch enrichment data from the external source for the given subject (Person or Company).

**Arguments:**
- `subject_type` — `:person` or `:company`
- `subject_id` — the internal ID of the Person or Company
- `config` — the provider config from the application environment

**Returns:**
- `{:ok, enriched_map}` — the enrichment succeeded. The map may be empty `%{}` if the external source has no data (honest empty), or contain enriched fields like `{"title": "VP", "company": "Acme"}`.
- `{:error, :not_configured}` — config is not ready; MUST be returned when `configured?(config)` is `false`.
- `{:error, :not_implemented}` — the required capability (`:person_enrich` or `:company_enrich` per subject_type) is not declared in `capabilities/0`.
- `{:error, reason}` — external service error, timeout, malformed response, etc.

**HARD RULE:** Never return `{:ok, _}` for work the provider did not do. Unconfigured is not an empty enrichment — it is a refusal.

**Example:**

```elixir
@impl true
def enrich(:person, person_id, config) do
  if :person_enrich in capabilities() do
    if configured?(config) do
      fetch_from_external_api(:person, person_id, config)
    else
      {:error, :not_configured}
    end
  else
    {:error, :not_implemented}
  end
end

defp fetch_from_external_api(:person, person_id, config) do
  # Call external API, return {:ok, map} or {:error, reason}
  case http_get("#{config.endpoint}/persons/#{person_id}", config.api_key) do
    {:ok, body} -> {:ok, body}
    {:error, reason} -> {:error, reason}
  end
end
```

### `redact_payload(payload :: map()) :: map()`

**Optional** (defaults to identity pass-through). Prune sensitive credentials and tokens from a raw vendor payload BEFORE it is logged, persisted, or transmitted.

This callback is exempt from the `configured?/1` check — it is a pure function with no side effects or network access.

**Example:**

```elixir
@impl true
def redact_payload(payload) when is_map(payload) do
  Map.drop(payload, [:api_key, "api_key", :token, "token"])
end
```

## PII Handling (Hosted Surface Concern — STATED, NOT TESTED by this seam)

When an adapter returns enriched personal data (email, phone, name, address), the host's enrichment consumer MUST route that data through the governed write path:

1. Use `Samen.Pii.WriteGuard` to authorize the write.
2. Use `Samen.Vault.Change` to materialize PII fields into vaulted columns.
3. Ensure the vaulted field reads are tested with the 3-proof masking case (tenant plane clear, operator-without-grant `••••`, plane flip detects leak).

**This is stated as a HOST OBLIGATION, not stated as done.** The pure seam shipped here
(`Samen.Enrichment`, `Samen.Enrichment.Provider`, `Samen.Enrichment.FakeProvider`) writes NO
PII and lands on NO record — `enrich/2` returns a plain map to the caller; nothing is persisted,
vaulted, or masked by this contract. `samen_core/test/enrichment_test.exs` therefore ships no
vault-routing or masking test — there is no vault-class field anywhere in the seam for such a
test to exercise. A host that wires a real adapter and persists its enriched output onto a
Person/Company record is the one obligated to add the `Samen.Pii.WriteGuard` +
`Samen.Vault.Change` write path AND the 3-proof `Samen.MaskingCase` read path at ITS
consumption point — not here.

**Reference:** `CLAUDE.md` §Per-plane masking tests; `Samen.MaskingCase` + T74 mailbox attachment tests.

## Honest Absence (Canonical Precedent)

The `Samen.Delivery.FakeProvider` (ESP delivery) is the canonical precedent for this contract. Study it:

- **Unconfigured:** every network callback returns `{:error, :not_configured}`.
- **Honest empty:** a message to an absent address succeeds with `{:ok, %{}}`, never a fake bounce.
- **Capability gating:** undeclared capabilities return `{:error, :not_implemented}`, not `{:error, :not_configured}`.
- **Test double:** process-local state, zero vendor coupling, drives the two-way loop end-to-end.

## Testing (Reference: `Samen.Enrichment.FakeProvider`)

CI uses the `FakeProvider` — a keyless, process-local test double that proves the enrichment loop without a real external service:

```elixir
FakeProvider.reset()
FakeProvider.configured?(%{})                     # => false
FakeProvider.configured?(%{configured: true})    # => true

FakeProvider.set_capabilities([:person_enrich])
FakeProvider.seed_enrichment(:person, 42, %{"title" => "VP"})

# In test:
{:ok, result} = Samen.Enrichment.enrich(:person, 42)
assert result == %{"title" => "VP"}
```

## Adoption Checklist

1. Implement `Samen.Enrichment.Provider` in a separate package (e.g., `samen_enrichment_clearbit`).
2. Test the adapter against the fail-honest contract this doc states (unconfigured refusal,
   honest-empty, capability gating). NOTE: unlike `Samen.Delivery.Provider`, there is currently
   NO `Samen.Enrichment.ProviderConformanceCase` shipped. The kit to follow if/when one is built
   for enrichment is `Samen.AdapterConformanceCase` (`samen_core`) — the shared CROSS-FAMILY
   conformance kit an adapter of ANY family can `use` directly, whose plain imported assertions
   (`load_fixtures!/1`, `assert_refusal_table!/1`, `assert_masked_payload_only!/2`,
   `assert_capture_no_leak!/2`, `assert_redaction!/3`) cover exactly the fail-honest contract
   above. `samen_postmark/test/conformance_test.exs` is the worked ESP example and
   `samen_anthropic/test/conformance_test.exs` the AI-provider one;
   `Samen.Delivery.ProviderConformanceCase` remains the ESP-only macro harness `samen_resend` and
   `samen_ses` consume. Until an enrichment adapter adopts the kit, an adapter author writes
   these conformance assertions by hand against `Samen.Enrichment.Provider`'s callbacks.
3. Wire it in the host config — never in core or demo.
4. Consume enrichment via the host's surface — enrich is NOT a framework surface, it is a host integration point.
5. For PII enrichment, route writes through `Samen.Vault.Change` + test with `Samen.MaskingCase`.
   This is a HOST OBLIGATION — the pure seam itself (this contract + `FakeProvider`) never writes
   PII and ships no vault-routing test; see "PII Handling" above.
6. INV-4: Core contains ZERO enrichment vendor dependencies.
