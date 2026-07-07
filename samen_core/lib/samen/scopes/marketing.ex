defmodule Samen.Scopes.Marketing do
  @moduledoc """
  The **Marketing** universal scope (T3.4; doc §"The inherited 80%" scope table:
  `campaign · segment · subscriber🔒 · template · send · email_event · suppression`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module inside a
  host's Ash domain expands into seven host-owned resources in the host's namespace —
  each a normal `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## PII — subscriber🔒

  `subscriber🔒` is the only 🔒 object in this scope. It carries:

    * `email` → vault `:pii_email` (scalar; column `pii_msu_email`)

  All other resources carry only opaque IDs and bounded data — no subject identity.

  ## Consent / suppression enforcement at send-time

  **Sends are refused if the target subscriber is suppressed.**

  The `Samen.Scopes.Marketing.Send` resource enforces consent/suppression at the
  action level: attempting to create a send whose subscriber_id appears in the
  `msp_suppression` table (for the same org) returns `{:error, :suppressed}` — the
  send row is never written and no Oban job is enqueued. This is the load-bearing
  red path for this scope.

  ## Sends are Oban jobs (webhooks_out-style queue)

  When a send is created and the subscriber is NOT suppressed, an
  `Samen.Scopes.Marketing.SendWorker` Oban job is enqueued in the `:webhooks_out`
  queue (the same queue convention as webhook deliveries; capped backoff, at-least-once,
  idempotency key on the send row's opaque ID). The send row is created and the job is
  enqueued in the **same Ecto.Multi transaction** via `Samen.Jobs.enqueue_in_tx/3`.

  ## Tier-0 config rows

  `Template` is the Marketing scope's Tier-0 config-row resource: one row per reusable
  email template per org (subject_line + body_html). Admins manage the template catalog
  without forking the product (malleability ladder bottom rung).

  ## Mounting Marketing (the host side)

      defmodule Demo.MarketingScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Marketing,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.MarketingScope
      end

  This defines, in the host's namespace:

    * `Demo.MarketingScope.Campaign`    — a marketing campaign (name/status/schedule)
    * `Demo.MarketingScope.Segment`     — an audience segment (filter criteria as jsonb)
    * `Demo.MarketingScope.Subscriber`  — 🔒 (email vault-routed; consent/status tracked)
    * `Demo.MarketingScope.Template`    — Tier-0: a reusable email template per org
    * `Demo.MarketingScope.Send`        — a single send event (campaign → subscriber)
    * `Demo.MarketingScope.EmailEvent`  — delivery/open/click/bounce/unsubscribe events
    * `Demo.MarketingScope.Suppression` — opt-out / bounce / unsubscribe suppression list

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.MarketingScope.Campaign`    → `mca`
    * `Demo.MarketingScope.Segment`     → `msg`
    * `Demo.MarketingScope.Subscriber`  → `msu`
    * `Demo.MarketingScope.Template`    → `mtp`
    * `Demo.MarketingScope.Send`        → `msn`
    * `Demo.MarketingScope.EmailEvent`  → `mee`
    * `Demo.MarketingScope.Suppression` → `msp`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    campaign: "mca",
    segment: "msg",
    subscriber: "msu",
    template: "mtp",
    send: "msn",
    email_event: "mee",
    suppression: "msp"
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

    campaign_mod = Module.concat(namespace, Campaign)
    segment_mod = Module.concat(namespace, Segment)
    subscriber_mod = Module.concat(namespace, Subscriber)
    template_mod = Module.concat(namespace, Template)
    send_mod = Module.concat(namespace, Send)
    email_event_mod = Module.concat(namespace, EmailEvent)
    suppression_mod = Module.concat(namespace, Suppression)

    quote do
      require Samen.Scopes.Marketing.Blueprint

      # Register the seven Marketing resources in the host domain.
      resources do
        resource(unquote(campaign_mod))
        resource(unquote(segment_mod))
        resource(unquote(subscriber_mod))
        resource(unquote(template_mod))
        resource(unquote(send_mod))
        resource(unquote(email_event_mod))
        resource(unquote(suppression_mod))
      end

      # Materialize resource modules in the host namespace. Each is a normal Samen
      # resource; the blueprint threads the host's otp_app/repo/domain and the
      # resource's literal, registry-checked abbrev.
      Samen.Scopes.Marketing.Blueprint.define_campaign(
        unquote(campaign_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.campaign)
      )

      Samen.Scopes.Marketing.Blueprint.define_segment(
        unquote(segment_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.segment)
      )

      Samen.Scopes.Marketing.Blueprint.define_subscriber(
        unquote(subscriber_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.subscriber)
      )

      Samen.Scopes.Marketing.Blueprint.define_template(
        unquote(template_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.template)
      )

      Samen.Scopes.Marketing.Blueprint.define_send(
        unquote(send_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.send),
        unquote(subscriber_mod),
        unquote(campaign_mod),
        unquote(template_mod),
        unquote(suppression_mod)
      )

      Samen.Scopes.Marketing.Blueprint.define_email_event(
        unquote(email_event_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.email_event),
        unquote(send_mod),
        unquote(subscriber_mod)
      )

      Samen.Scopes.Marketing.Blueprint.define_suppression(
        unquote(suppression_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.suppression),
        unquote(subscriber_mod)
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
          "use Samen.Scopes.Marketing, abbrevs: must be a compile-time map literal " <>
            "(%{campaign: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
