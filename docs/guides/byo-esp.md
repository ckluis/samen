# Bring-Your-Own ESP — wiring real email delivery without samen owning an adapter

**The boundary.** Samen does NOT ship a first-party email integration wired into every host by
default, and deliberately so (ADR-014, and the F1 decision to decline auto-wired first-party
adapters). Outbound email routes through a pluggable, **fail-honest** contract —
`Samen.Delivery.Provider` (ADR-038 §4 — the ADR-014 `Samen.Delivery.Adapter` contract, finalized
and renamed) — and the kernel ships:

| Adapter | Role | `deliver/2` when unconfigured |
|---|---|---|
| `Samen.Delivery.LocalSink` | dev/test | `{:ok, %{sink: true}}` — honest "captured, not delivered" |
| `Samen.Delivery.Smtp` | skeleton | `{:error, :not_configured}` — never a fake `{:ok, _}` |
| `Samen.Delivery.Api` (generic HTTP ESP) | skeleton | `{:error, :not_configured}` — never a fake `{:ok, _}` |

Additionally, first-party-but-separate real ESP adapter packages (`samen_postmark`, and
`samen_ses`/`samen_resend` following the same shape) ship as standalone mix projects (ADR-038
§8.1) implementing this SAME behaviour — pick one of those instead of BYO-ing your own if it fits.

The load-bearing rule (Invariant D1, enforced by `Samen.Scopes.Marketing.SendWorker`): a send
reaches `:delivered` **if and only if** a *configured* adapter returned `{:ok, receipt}`. Your job
is to supply that configured adapter — in your HOST app, pulling whatever client library it needs
(or select one of the first-party packages above) — so samen never has to own a provider
dependency or a provider's failure modes.

This guide shows the two BYO shapes. `use Samen.Delivery.Provider` gives you overridable, honest
defaults for `capabilities/0` (`[]`), `verify_and_parse_event/3`/`parse_inbound/3`
(`{:error, :not_implemented}`), and `redact_payload/1` (identity) — so a minimal BYO adapter still
only implements TWO functions: `configured?/1` + `deliver/2`.

---

## The contract

```elixir
@callback configured?(config :: map()) :: boolean()
@callback deliver(message :: Samen.Delivery.Message.t(), config :: map()) ::
            {:ok, receipt :: map()} | {:error, reason :: term()}
```

- `configured?/1` — the gate. Return `true` ONLY when you have everything to actually dispatch
  (creds, endpoint). The SendWorker will NOT call `deliver/2` on an adapter that answers `false`;
  it treats it as fail-honest `:blocked` in non-test envs.
- `deliver/2` — return `{:ok, receipt}` ONLY when the message was actually dispatched. NEVER
  return `{:ok, _}` for a no-op — that is the exact lie the contract abolishes.

The `%Samen.Delivery.Message{}` you receive is **token-only**: the recipient is a vault reference,
not plaintext. Reveal the recipient email through the vault at the point of dispatch (governed
read) — do not expect a plaintext address on the struct.

---

## Option A — SMTP via `gen_smtp` (host-owned)

1. Add the client to YOUR host's deps (not samen's):

   ```elixir
   # driftwood/mix.exs
   {:gen_smtp, "~> 1.2"}
   ```

2. Implement the behaviour in your host, pulling `gen_smtp` here (samen stays web/SMTP-dep-free):

   ```elixir
   defmodule Driftwood.Delivery.GenSmtp do
     use Samen.Delivery.Provider

     @impl true
     def configured?(%{host: h, username: u, password: p})
         when is_binary(h) and is_binary(u) and is_binary(p) and h != "" and u != "" and p != "",
         do: true
     def configured?(_), do: false

     @impl true
     def deliver(%Samen.Delivery.Message{} = msg, config) do
       # Reveal the recipient through the vault at dispatch (governed read), build the RFC822
       # body from msg, then hand to gen_smtp. Return {:ok, receipt} ONLY on a real send.
       to = Driftwood.Delivery.recipient_email!(msg)   # your governed vault reveal

       email = {config.username, [to], :binary.bin_to_list(render(msg))}

       relay = [relay: config.host, username: config.username, password: config.password,
                port: Map.get(config, :port, 587), tls: :always, auth: :always]

       case :gen_smtp_client.send_blocking(email, relay) do
         receipt when is_binary(receipt) -> {:ok, %{smtp: true, receipt: receipt}}
         {:error, _type, reason} -> {:error, reason}
         {:error, reason} -> {:error, reason}
       end
     end

     defp render(_msg), do: "..."  # your MIME assembly
   end
   ```

3. Point the kernel at your adapter + creds via config (creds from the environment, never
   committed):

   ```elixir
   config :samen_core, Samen.Delivery,
     adapter: Driftwood.Delivery.GenSmtp,
     config: %{
       host: System.get_env("SMTP_HOST"),
       username: System.get_env("SMTP_USER"),
       password: System.get_env("SMTP_PASS"),
       port: 587
     }
   ```

## Option B — HTTP ESP (SendGrid / Postmark / SES)

Identical shape; the client is an HTTP lib (`Req`/`Finch`) in YOUR host:

```elixir
defmodule Driftwood.Delivery.Esp do
  use Samen.Delivery.Provider

  @impl true
  def configured?(%{api_key: k, endpoint: e})
      when is_binary(k) and is_binary(e) and k != "" and e != "", do: true
  def configured?(_), do: false

  @impl true
  def deliver(%Samen.Delivery.Message{} = msg, %{api_key: key, endpoint: endpoint}) do
    to = Driftwood.Delivery.recipient_email!(msg)      # governed vault reveal

    case Req.post(endpoint,
           auth: {:bearer, key},
           json: %{to: to, subject: msg.subject, body: msg.rendered_body}) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, %{esp: true, id: body["id"]}}
      {:ok, %{status: s}} -> {:error, {:esp_status, s}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

```elixir
config :samen_core, Samen.Delivery,
  adapter: Driftwood.Delivery.Esp,
  config: %{api_key: System.get_env("ESP_API_KEY"), endpoint: System.get_env("ESP_ENDPOINT")}
```

---

## Why samen does not own this

- **No provider lock-in / no provider dep in the kernel.** The behaviour references no HTTP/SMTP
  library; the client lives in your host, so samen's dependency surface (and its failure modes)
  stays provider-free.
- **The fail-honest boundary holds either way.** With no adapter configured, `configured?/1` is
  `false`, `deliver/2` returns `{:error, :not_configured}`, and the SendWorker blocks the send —
  a marketing "sent" never lies to a tenant. Wiring an adapter is purely additive.
- **PII stays governed.** The message is token-only; the recipient reveal is a governed vault read
  at the point of dispatch, so masking-by-construction is never bypassed to send an email.

## Verify

- [ ] `configured?/1` returns `false` with creds absent, `true` with them present.
- [ ] A send with your adapter configured reaches `:delivered` only on a real `{:ok, receipt}`.
- [ ] A send with creds removed is BLOCKED (not silently "delivered").
