defmodule Samen.Scopes.Support do
  @moduledoc """
  The **Support** universal scope (T3.6; doc §"The inherited 80%" scope table:
  `ticket · conversation · message🔒 · agent🔒 · sla · macro · csat`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module inside a
  host's Ash domain expands into seven host-owned resources in the host's namespace —
  each a normal `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## PII — message🔒 and agent🔒

  Two resources carry 🔒 PII:

  - `message🔒` — `body` → vault `:pii_body` (scalar; column `pii_<abbrev>_body`).
    Free-text conversation content. See the blueprint moduledoc for the
    free-text-vs-composite tension documentation.

  - `agent🔒` — `full_name` → vault `:pii_name` (composite, no `pii_` prefix);
    `email` → vault `:pii_email` (scalar; column `pii_<abbrev>_email`).

  All other resources carry only opaque IDs, bounded enums, and numbers — no subject
  identity data.

  ## SLA breach detection — Oban cron

  The scope ships a dedicated Oban worker (`Samen.Scopes.Support.SlaBreachWorker`)
  that runs every minute (`:maintenance` queue, concurrency 1). Each tick scans
  `ticket` for rows where `sla_breach_at <= now()` and `breached == false`,
  marks them breached, and emits a `support.ticket.breached` `aud_event`.

  Wire the cron in your Oban config:

      {Oban.Plugins.Cron,
        crontab: [
          {"* * * * *", Samen.Scopes.Support.SlaBreachWorker}
        ]}

  And configure the ticket resource:

      config :samen_core, :support_sla_breach_ticket_resource, Demo.SupportScope.Ticket

  ## Tier-0 config rows

  - `Sla` — per-org SLA policies (first-response / resolution targets in minutes per
    priority). Tenants configure their SLA promise without forking the product.
  - `Macro` — per-org reusable canned responses. Agents use macros to reply
    quickly to common ticket types.

  ## Mounting the Support scope (the host side)

      defmodule Demo.SupportScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Support,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.SupportScope
      end

  This defines, in the host's namespace:

    * `Demo.SupportScope.Ticket`       — the top-level ticket (SLA deadline, priority, status)
    * `Demo.SupportScope.Conversation` — a message thread on a ticket
    * `Demo.SupportScope.Message`      — 🔒 (body vault-routed; free-text)
    * `Demo.SupportScope.Agent`        — 🔒 (full_name/email vault-routed)
    * `Demo.SupportScope.Sla`          — Tier-0: SLA policies per org
    * `Demo.SupportScope.Macro`        — Tier-0: canned responses per org
    * `Demo.SupportScope.Csat`         — customer satisfaction response

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.SupportScope.Ticket`       → `stk`
    * `Demo.SupportScope.Conversation` → `scv`
    * `Demo.SupportScope.Message`      → `smg`
    * `Demo.SupportScope.Agent`        → `sag`
    * `Demo.SupportScope.Sla`          → `ssl`
    * `Demo.SupportScope.Macro`        → `smc`
    * `Demo.SupportScope.Csat`         → `scs`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    ticket: "stk",
    conversation: "scv",
    message: "smg",
    agent: "sag",
    sla: "ssl",
    macro: "smc",
    csat: "scs"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (the base macro validates abbrevs
    # caller-side and requires a compile-time literal — do NOT pass an `abbrevs.foo` AST
    # expression into the blueprint).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    ticket_mod = Module.concat(namespace, Ticket)
    conversation_mod = Module.concat(namespace, Conversation)
    message_mod = Module.concat(namespace, Message)
    agent_mod = Module.concat(namespace, Agent)
    sla_mod = Module.concat(namespace, Sla)
    macro_mod = Module.concat(namespace, Macro)
    csat_mod = Module.concat(namespace, Csat)

    quote do
      require Samen.Scopes.Support.Blueprint

      # Register the seven Support resources in the host domain.
      resources do
        resource(unquote(ticket_mod))
        resource(unquote(conversation_mod))
        resource(unquote(message_mod))
        resource(unquote(agent_mod))
        resource(unquote(sla_mod))
        resource(unquote(macro_mod))
        resource(unquote(csat_mod))
      end

      # Materialize resource modules in the host namespace. Each is a normal Samen
      # resource; the blueprint threads the host's otp_app/repo/domain and the
      # resource's literal, registry-checked abbrev.
      Samen.Scopes.Support.Blueprint.define_sla(
        unquote(sla_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.sla)
      )

      Samen.Scopes.Support.Blueprint.define_ticket(
        unquote(ticket_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.ticket),
        unquote(sla_mod)
      )

      Samen.Scopes.Support.Blueprint.define_conversation(
        unquote(conversation_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.conversation),
        unquote(ticket_mod)
      )

      Samen.Scopes.Support.Blueprint.define_agent(
        unquote(agent_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.agent)
      )

      Samen.Scopes.Support.Blueprint.define_message(
        unquote(message_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.message),
        unquote(conversation_mod),
        unquote(agent_mod)
      )

      Samen.Scopes.Support.Blueprint.define_macro(
        unquote(macro_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.macro)
      )

      Samen.Scopes.Support.Blueprint.define_csat(
        unquote(csat_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.csat),
        unquote(ticket_mod),
        unquote(agent_mod)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults. Fail closed if a caller passes
  # a non-map or a non-string abbrev.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Support, abbrevs: must be a compile-time map literal " <>
            "(%{ticket: \"stk\", ...}). Got: #{Macro.to_string(other)}"
  end
end
