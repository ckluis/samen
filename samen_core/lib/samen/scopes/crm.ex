defmodule Samen.Scopes.Crm do
  @moduledoc """
  The **CRM** universal scope (T3.2; doc §"The inherited 80%" scope table:
  `company · person🔒 · opportunity · pipeline · activity · attachment`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module
  inside a host's Ash domain expands into six host-owned resources in the host's
  namespace — each a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain`.

  ## PII — the canonical vault case

  `person🔒` is the central object of this scope and the vision doc's canonical
  PII vault case (doc §core "The proof — one base, many shapes"). It composes
  `Samen.Fragments.CorePerson` via `base:` — a single physical table carrying:

    * `full_name`   → vault `:pii_name`  (composite, column `per_full_name`)
    * `emails`      → vault `:pii_email` (composite, column `per_emails`)
    * `phones`      → vault `:pii_phone` (composite, column `per_phones`)

  Composite types route by vault name (no `pii_` prefix); scalars would carry
  the `pii_` prefix. See vision doc §core "PII routing note".

  ## Tier-0 config rows

  `Pipeline` is the CRM's Tier-0 config-row resource: one row per pipeline stage
  per org (e.g. Lead → Qualified → Proposal → Closed Won). Admins bend the
  stage catalog without forking the product.

  ## Mounting CRM (the host side)

      defmodule Demo.Crm do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Crm,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Crm
      end

  This defines, in the host's namespace:

    * `Demo.Crm.Company`     — a B2B company record (no PII)
    * `Demo.Crm.Person`      — a CRM contact 🔒 (name/emails/phones vault-routed)
    * `Demo.Crm.Pipeline`    — Tier-0 config rows (deal-stage catalog per org)
    * `Demo.Crm.Opportunity` — a deal linked to a company + pipeline stage
    * `Demo.Crm.Activity`    — a call/email/meeting/note linked to any CRM object
    * `Demo.Crm.Attachment`  — a file reference linked to any CRM object

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.Crm.Company`     → `cmp`
    * `Demo.Crm.Person`      → `per`
    * `Demo.Crm.Pipeline`    → `pip`
    * `Demo.Crm.Opportunity` → `opp`
    * `Demo.Crm.Activity`    → `act`
    * `Demo.Crm.Attachment`  → `att`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    company: "cmp",
    person: "per",
    pipeline: "pip",
    opportunity: "opp",
    activity: "act",
    attachment: "att"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string.
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    company_mod = Module.concat(namespace, Company)
    person_mod = Module.concat(namespace, Person)
    pipeline_mod = Module.concat(namespace, Pipeline)
    opportunity_mod = Module.concat(namespace, Opportunity)
    activity_mod = Module.concat(namespace, Activity)
    attachment_mod = Module.concat(namespace, Attachment)

    quote do
      require Samen.Scopes.Crm.Blueprint

      # Register the six CRM resources in the host domain.
      resources do
        resource(unquote(company_mod))
        resource(unquote(person_mod))
        resource(unquote(pipeline_mod))
        resource(unquote(opportunity_mod))
        resource(unquote(activity_mod))
        resource(unquote(attachment_mod))
      end

      # Materialize resource modules in the host namespace.
      Samen.Scopes.Crm.Blueprint.define_company(
        unquote(company_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.company)
      )

      Samen.Scopes.Crm.Blueprint.define_person(
        unquote(person_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.person),
        unquote(company_mod)
      )

      Samen.Scopes.Crm.Blueprint.define_pipeline(
        unquote(pipeline_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.pipeline)
      )

      Samen.Scopes.Crm.Blueprint.define_opportunity(
        unquote(opportunity_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.opportunity),
        unquote(company_mod),
        unquote(pipeline_mod)
      )

      Samen.Scopes.Crm.Blueprint.define_activity(
        unquote(activity_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.activity),
        unquote(company_mod),
        unquote(person_mod),
        unquote(opportunity_mod)
      )

      Samen.Scopes.Crm.Blueprint.define_attachment(
        unquote(attachment_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.attachment),
        unquote(company_mod),
        unquote(person_mod),
        unquote(opportunity_mod)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults.
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
          "use Samen.Scopes.Crm, abbrevs: must be a compile-time map literal " <>
            "(%{company: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
