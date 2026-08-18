defmodule Samen.Scopes.SalesOps do
  @moduledoc """
  The **SalesOps** universal scope (F6+F7; spec §F6,§F7,§F8; T48). Ships as a
  **library-authored blueprint** (ADR-004), same shape as
  `Samen.Scopes.Work`/`Samen.Scopes.Docs`/`Samen.Scopes.Tags`/`Samen.Scopes.Locations`:
  `use`-ing this module inside a host's Ash domain expands into TWO host-owned
  resources in the host's namespace, each a normal `use Samen.Resource` with the
  host's `otp_app`, `repo`, and `domain`.

  ## Resources — `vendor`, `lead`

  - **`Vendor`** (F6) — CRM-adjacent: the companies a tenant BUYS FROM (as opposed to
    `Samen.Scopes.Crm.Company`, the companies a tenant SELLS TO). A standalone
    resource, not a re-identification of CRM Company — a vendor and a customer are
    distinct business relationships that can coexist for the same real-world company.
    Carries ONE embedded vendor contact (`contact_name`/`contact_emails`/
    `contact_phones`, vault-routed). Archivable (ADR-040 §5.9).
  - **`Lead`** (F7) — a SALES lead, distinct from `Samen.Scopes.Marketing.Subscriber`
    (a marketing opt-in list member). Lead carries its OWN table
    (`<abbrev>_lead`, never `<abbrev>_subscriber`), its own PII
    (`full_name`/`emails`/`phones`, vault-routed — the SAME `Samen.Type.FullName`/
    `Emails`/`Phones` composites `Samen.Fragments.CorePerson` uses, so a converted
    Lead casts 1:1 into a CRM Person), a `status` enum with a `:converted` terminal
    state, and a `value` estimate typed `Samen.Type.Money` (H1/T12 — exact
    Decimal-backed cents, never a float, INV-2). Its **`:convert`** action is the
    F7 lead → contact/opportunity conversion: creates a host CRM `Person` (the
    "Contact") + CRM `Opportunity` (carrying `Lead.value` unchanged) and links the
    Lead back to both, atomically, refusing a second conversion
    (`Samen.Scopes.SalesOps.AlreadyConverted`). Archivable (ADR-040 §5.9).

  ## Mounting SalesOps (the host side) — requires an ALREADY-MOUNTED CRM scope

  `Lead.convert` targets real host CRM resources, so the host must pass the
  CRM `Person`/`Opportunity`/`Company` modules it already mounted via
  `Samen.Scopes.Crm` (exactly how `Samen.Scopes.Crm.Blueprint.define_attachment`
  itself takes `company_mod`/`person_mod`/`opportunity_mod` as compile-time
  parameters — this is the SAME cross-resource-reference technique, just crossing
  a scope-module boundary instead of a macro-call boundary within one file; the
  established precedent for that is `Driftwood.Freight`'s
  `belongs_to :carrier, Driftwood.Crm.Company`, defined in a DIFFERENT file from
  `Driftwood.Crm` and compiling cleanly today):

      defmodule Demo.SalesOps do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.SalesOps,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.SalesOps,
          person_mod: Demo.CrmScope.Person,
          opportunity_mod: Demo.CrmScope.Opportunity,
          company_mod: Demo.CrmScope.Company,
          abbrevs: %{vendor: "dsv", lead: "dsl"}

  This defines, in the host's namespace:

    * `Demo.SalesOps.Vendor`
    * `Demo.SalesOps.Lead`

  ## PII map (INV-1)

  | Resource | Field                                | Vault       | Shape (composite, no `pii_` prefix) |
  |----------|---------------------------------------|-------------|--------------------------------------|
  | Vendor   | `contact_name`                        | `:pii_name` | `Samen.Type.FullName`                |
  | Vendor   | `contact_emails`                      | `:pii_email`| `Samen.Type.Emails`                  |
  | Vendor   | `contact_phones`                      | `:pii_phone`| `Samen.Type.Phones`                  |
  | Lead     | `full_name`                           | `:pii_name` | `Samen.Type.FullName`                |
  | Lead     | `emails`                              | `:pii_email`| `Samen.Type.Emails`                  |
  | Lead     | `phones`                              | `:pii_phone`| `Samen.Type.Phones`                  |

  `vendor.name` (the vendor COMPANY's name), `lead.company_name` (the lead's
  freeform employer label), `status`/`source`/`notes`/`value`/timestamps are all
  non-PII. Reusing the `:pii_name`/`:pii_email`/`:pii_phone` vault-name labels
  `Samen.Fragments.CorePerson` already declares is safe and precedented — the
  vault row's real crypto-shred unit is the owning resource's OWN primary key
  (`subject_id`), not the vault-name string, and multiple host CRM `Person` mounts
  already share those same three vault names today.

  ## No object-ref attachment (unlike Docs/Tags; mirrors T47 Location)

  Neither Vendor nor Lead is attachable to arbitrary objects the way
  Doc/Note/Tagging are — both are TARGET objects other resources (Docs, Tags,
  future Attachments) anchor TO via the generic object-ref, not anchors
  themselves. So neither carries a `subject_key`/`subject_id` pair.

  ## Soft-delete (ADR-040 §5.9)

  Both `Vendor` and `Lead` are `archivable: true` (user-managed nouns).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    person_mod = Keyword.fetch!(opts, :person_mod) |> Macro.expand(__CALLER__)
    opportunity_mod = Keyword.fetch!(opts, :opportunity_mod) |> Macro.expand(__CALLER__)
    company_mod = Keyword.fetch!(opts, :company_mod) |> Macro.expand(__CALLER__)

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    vendor_mod = Module.concat(namespace, Vendor)
    lead_mod = Module.concat(namespace, Lead)

    quote do
      require Samen.Scopes.SalesOps.Blueprint

      resources do
        resource(unquote(vendor_mod))
        resource(unquote(lead_mod))
      end

      Samen.Scopes.SalesOps.Blueprint.define_vendor(
        unquote(vendor_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.vendor)
      )

      Samen.Scopes.SalesOps.Blueprint.define_lead(
        unquote(lead_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.lead),
        unquote(person_mod),
        unquote(opportunity_mod),
        unquote(company_mod)
      )
    end
  end

  # `abbrevs:` is REQUIRED (no scope-default map) — mirrors Docs/Tags/Locations:
  # every host takes a fresh allocator-proposed abbrev, never a scope-owned default.
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.SalesOps, abbrevs: must be a compile-time map literal " <>
            "(%{vendor: \"abc\", lead: \"def\"}). Got: #{Macro.to_string(other)}"
  end
end
