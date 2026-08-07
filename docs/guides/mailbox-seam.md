# The mailbox seam — wiring a real two-way CRM email sync

**The boundary.** Samen does NOT ship an IMAP/Gmail/Microsoft-Graph connector, and deliberately so
(spec §I1, ruling M8; the same rule ADR-014/ADR-024/ADR-026 set for delivery, files and deploy).
`samen_core` owns the whole *capability* — the behaviour, the normalized structs, the CRM matching,
the threading, the vaulting, the timeline reads, the settings surface — and owns **zero** vendor
coupling (INV-4, proved by `samen_core/test/mailbox_vendor_free_test.exs`: no IMAP/HTTP dependency
in `mix.exs`, no vendor module named anywhere in `lib`).

What ships in the kernel:

| Module | Role | Behaviour when unconfigured |
|---|---|---|
| `Samen.Mailbox.Provider` | the contract | — |
| `Samen.Mailbox.FakeProvider` | the honest, KEYLESS double CI runs | `{:error, :not_configured}` on every network callback |
| `Samen.Mailbox.Sync` | connect / sync / send + CRM threading | `{:error, :not_configured}`, **before any write** |
| `Samen.Mailbox.Match` | vaulted-address → Person/Company matching | — |
| `Samen.Scopes.Mailbox` | the host-mountable `Connection` 🔒 + `MailMessage` 🔒 resources | — |

A **real** adapter is a separate package behind an explicit host flag, and is **never exercised in
CI**. CI runs the fake; the fake is honest about being a fake (`fake: true` in its receipts, all
state process-local) and refuses everything when it has no credentials.

The load-bearing rule: **a message appears on a CRM timeline if and only if a configured provider
actually returned it.** An unconfigured sync returns `{:error, :not_configured}` — never
`{:ok, %{synced: 0}}`. "Unconfigured" and "connected but quiet" are different facts, and
`/crm/mailbox` renders them as different pages.

---

## Turning a real adapter on

```elixir
# config/runtime.exs — the EXPLICIT flag. Unset (the default, and CI's state) = no provider.
config :samen_core, :mailbox_provider, {MyImapAdapter.Provider, %{
  host: System.fetch_env!("IMAP_HOST"),
  oauth_client_id: System.fetch_env!("MAILBOX_CLIENT_ID"),
  oauth_client_secret: System.fetch_env!("MAILBOX_CLIENT_SECRET")
}}
```

`Samen.Mailbox.provider_configured?/0` reads that flag and asks the adapter itself. There is no
implicit default adapter, and nothing ever falls back to the fake.

---

## The callback roster — EVERY function a real adapter must implement

`use Samen.Mailbox.Provider` injects overridable, fail-honest defaults for `capabilities/0`,
`disconnect/2`, `parse_push/3` and `redact_payload/1`, so a **minimal** adapter implements only the
four required callbacks. A production connector implements all eight.

### 1. `configured?(config :: map()) :: boolean()` — REQUIRED

The gate, and the single source of truth. Return `true` ONLY when you hold everything needed to
actually reach a mailbox (client id/secret, host, token store). Every other callback except
`capabilities/0` and `redact_payload/1` MUST return `{:error, :not_configured}` when this is
`false` for the same config.

**Precedence when both are absent (binding).** `capabilities/0` is checked FIRST: an adapter that
is both unconfigured *and* lacks the capability answers `{:error, :not_implemented}`, not
`{:error, :not_configured}`. `:not_configured` means "wire credentials and this will work";
`:not_implemented` means "this adapter will never do that" — a permanent absence must not be
reported as a fixable one. This mirrors `Samen.Delivery.FakeProvider`, the shipped ESP precedent.
The capability-gated callbacks are `fetch/3`, `send/3`, `parse_push/3`; `connect/2` and
`disconnect/2` are not gated (every mailbox provider connects) and answer `{:error, :not_configured}`
when unconfigured.

### 2. `capabilities() :: [capability]` — defaulted to `[]`

Honest declaration, NOT config-dependent. The bounded enum:

| Capability | Means |
|---|---|
| `:inbound_sync` | `fetch/3` really pulls mail |
| `:outbound_send` | `send/3` really sends AS the connected mailbox |
| `:push_notifications` | `parse_push/3` really parses a vendor push payload |
| `:thread_history` | the provider returns a stable `thread_id` (so threading need not fall back on RFC-5322 headers) |

Checked in BOTH directions: an undeclared capability must refuse with `{:error, :not_implemented}`
even when configured; a declared one must genuinely work.

### 3. `connect(params :: map(), config :: map()) :: {:ok, Samen.Mailbox.Account.t()} | {:error, term}` — REQUIRED

Per-user mailbox connect. `params` is host-authoritative handshake input (an OAuth authorization
code, an IMAP username + app password, a delegated-permission grant) — plus `:user_id`, which the
framework persists. Return `{:ok, %Samen.Mailbox.Account{external_account_id:, address:, cursor:}}`
ONLY after the mailbox was genuinely reached. Never synthesize an account you could not verify.

`address` is 🔒 — the framework persists it vault-routed (`:pii_email`); there is no plaintext
address column on the `Connection` resource.

### 4. `disconnect(account_ref :: String.t(), config :: map()) :: :ok | {:error, term}` — defaulted to `{:error, :not_implemented}`

Revoke the OAuth grant / drop the IMAP session. Return `:ok` only when the provider actually
released it. The `Connection` row is kept and marked `:disconnected` — its already-synced messages
stay on the timeline.

### 5. `fetch(account_ref, cursor, config) :: {:ok, %{messages: [Message.t()], cursor: cursor}} | {:error, term}` — REQUIRED

Pull one **bounded** page starting at `cursor` (an IMAP `UIDNEXT`, a Gmail `historyId`, a Graph
`deltaLink` — opaque to core, round-tripped through the `Connection` row).

The page MUST include **both directions the mailbox holds**: mail that arrived, and mail the user
SENT from that mailbox (`%Message{direction: :outbound}`, i.e. the Sent folder). That is what makes
the sync two-way even for mail composed outside the product. Set `external_id` on every message —
it is the idempotency key that keeps a replayed page from double-posting a conversation onto a
customer's timeline.

Normalize the vendor envelope into `%Samen.Mailbox.Message{}` INSIDE the adapter. Core never learns
a vendor's field names.

### 6. `send(message :: Message.t(), account_ref, config) :: {:ok, receipt :: map()} | {:error, term}` — REQUIRED

Send AS the connected mailbox. Return `{:ok, receipt}` ONLY when actually dispatched, and put the
provider's message id on the receipt as `:external_id` — the framework records the send on the CRM
timeline with that id, so the copy your next `fetch/3` returns from the Sent folder is deduped
rather than posted twice.

### 7. `parse_push(raw_body :: binary(), headers, config) :: {:ok, [Message.t()]} | {:error, term}` — defaulted to `{:error, :not_implemented}`

Turn a vendor push/webhook payload (Gmail `watch`, Graph subscription, an IMAP IDLE bridge) into
normalized messages. **Signature verification is the adapter's job**: a bad signature returns
`{:error, :invalid_signature}` and parses NOTHING.

### 8. `redact_payload(payload :: map()) :: map()` — defaulted to identity

Prune PII and secrets from a raw vendor payload BEFORE anything about it is persisted or logged.
Pure — no creds, no network — and therefore exempt from the `configured?/1` gate.

---

## What the framework does with what you return (so you don't reimplement it)

1. **Bounds and sanitizes** every field (byte caps; `Samen.Support.Inbound.Sanitize.plain_text/1`,
   the T111/T59 stored-XSS lineage) before the write.
2. **Matches the counterparty** (sender for inbound, first recipient for outbound) to a CRM
   `Person` by that person's **vaulted** `emails` — read org-scoped and bounded, resolved through
   `Samen.Api.PiiResolution` on the tenant plane, compared normalized (trim + NFC + downcase). No
   plaintext email column exists to query, and `Samen.Mailbox.Match` never touches the vault
   directly. An unmatched message is recorded, anchored to nothing — never attached to an
   arbitrary record.
3. **Anchors** the message with the generic `(subject_key, subject_id)` object-ref
   (`"crm.person"` / `"crm.company"`, the ADR-041 §6.1 shape) plus a secondary `company_id`, so a
   person-anchored message also lands on that person's company timeline.
4. **Vaults** `subject` + `body` (`:pii_body`) and `counterparty_address` (`:pii_email`). The CRM
   detail timeline renders them through `PiiResolution`: tenant clear, operator-without-grant
   `••••`, never a `vt_*` token in the DOM.
5. **Dedupes** on your `external_id`, per org.
6. **Records the direction** on the timeline entry, so inbound and outbound read as the two legs of
   one conversation.

---

## Mounting the scope (the host side — ≈0 authored LOC)

```elixir
defmodule MyApp.Mailbox do
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Mailbox,
    otp_app: :my_app,
    repo: MyApp.Repo,
    namespace: MyApp.Mailbox,
    abbrevs: %{connection: "abc", mail_message: "abd"}   # via mix samen.abbrev.reserve (ADR-023)
end
```

Then build a `Samen.Mailbox.Config` naming your own modules and call
`Samen.Mailbox.{connect,sync,send}`. The CRM detail timelines pick the messages up automatically:
`Samen.Web.CRM.Reads` derives your `Mailbox.MailMessage` from the CRM mount's host root, and
returns an honest `[]` when the scope is not mounted. `Samen.WebTest.Mailbox` (samen_web
`test/support/mailbox.ex`) is the reference adopter — the whole adoption is the `use` block above.

> Abbrevs are allocated ONLY through `mix samen.abbrev.reserve` (ADR-023). Never hand-edit
> `priv/abbrev_registry.json`.

---

## Writing the adapter — the shape

```elixir
defmodule MyImapAdapter.Provider do
  use Samen.Mailbox.Provider

  @impl true
  def configured?(%{host: h, username: u, password: p})
      when is_binary(h) and is_binary(u) and is_binary(p),
      do: true

  def configured?(_), do: false

  @impl true
  def capabilities, do: [:inbound_sync, :outbound_send]

  @impl true
  def connect(params, config) do
    if configured?(config) do
      # …real IMAP LOGIN / OAuth exchange…
      {:ok, %Samen.Mailbox.Account{external_account_id: mailbox_id, address: addr, cursor: uidnext}}
    else
      {:error, :not_configured}
    end
  end

  @impl true
  def fetch(account_ref, cursor, config) do
    if configured?(config) do
      # …UID FETCH since `cursor`, INBOX **and** Sent; normalize each into %Samen.Mailbox.Message{}…
      {:ok, %{messages: messages, cursor: next_uid}}
    else
      {:error, :not_configured}
    end
  end

  @impl true
  def send(%Samen.Mailbox.Message{} = message, account_ref, config) do
    if configured?(config) do
      # …real SMTP/JMAP submission…
      {:ok, %{external_id: provider_message_id}}
    else
      {:error, :not_configured}
    end
  end
end
```

### The three ways to get this wrong

1. Returning `{:ok, %{messages: [], cursor: nil}}` when you are not configured. That is the lie the
   contract abolishes — an empty inbox and a dead connector must not look the same.
2. Returning `{:ok, _}` from `send/3` for a message you queued but did not dispatch. The timeline
   entry it produces is a claim to the tenant that mail went out.
3. Declaring a capability you do not implement (or refusing one you do). The conformance
   expectation is checked in both directions.

---

## Tests to copy

| File | Proves |
|---|---|
| `samen_core/test/mailbox_provider_test.exs` | the fail-honest contract, both capability directions, `Sync` refusing before any write |
| `samen_core/test/mailbox_vendor_free_test.exs` | INV-4 — no vendor mailbox dep or module in the kernel |
| `samen_web/test/samen/web/mailbox_sync_test.exs` | the full two-way loop on real Postgres: vaulted-address matching (asserted via granted resolution), person + company anchoring, outbound recording, idempotency, refutable non-matching |
| `samen_web/test/samen/web/mailbox_timeline_masking_test.exs` | the INV-1 three-proof on the CRM timeline render |
| `samen_web/test/samen/web/crm_mailbox_settings_test.exs` | the honest empty state at `/crm/mailbox` |
