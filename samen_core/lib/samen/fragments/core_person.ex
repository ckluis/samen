defmodule Samen.Fragments.CorePerson do
  @moduledoc """
  The **Core.Person** fragment (doc §core "The proof — one base, many shapes";
  vision doc code block).

  A `Spark.Dsl.Fragment` of `Ash.Resource` — a tableless bundle of shared
  attributes and PII routing, with NO data layer and NO table of its own. It
  declares the extensions whose DSL it uses (`Samen.Pii` for the `pii do`
  block, `Samen.Catalog` as a marker). It is folded into a composed resource via
  `use Samen.Resource, base: Samen.Fragments.CorePerson`; the fragment's
  attributes and PII declarations become columns of that resource, prefixed with
  the composing resource's own abbrev.

  ## The nine core person columns (vision doc §core person table)

      per_id uuid                  — injected by base macro (CoreAttributes)
      per_full_name FullName       — PII → pii_name vault (composite, no pii_ prefix)
      per_emails Emails            — PII → pii_email vault (composite, no pii_ prefix)
      per_phones Phones            — PII → pii_phone vault (composite, no pii_ prefix)
      per_job_title text           — core (non-PII)
      per_company_id uuid          — FK → CRM company (injected by composing resource)
      per_custom jsonb             — Tier-1 bag
      per_inserted_at utc_datetime — injected by base macro (CoreAttributes)
      per_updated_at utc_datetime  — injected by base macro (CoreAttributes)

  ## Fragment vs resource — the FK rule

  `Samen.Fragments.CorePerson` is the *fragment*: tableless, no data layer.
  `Demo.Crm.Person` (or any composed resource) is the *resource*: it HAS a
  table. Every `belongs_to` relationship MUST target the composed resource
  (the one with a table), never this fragment. The fragment is folded in;
  references resolve to the table it was folded into.

  ## Abbrev inheritance

  The fragment's attributes are prefixed with the COMPOSING RESOURCE's abbrev,
  not a fragment-level prefix. So when `Demo.Crm.Person` (abbrev `per`) folds
  in this fragment, `full_name` → column `per_full_name`. A different vertical
  that composes this fragment with abbrev `pat` would get `pat_full_name`.

  ## PII routing

  Composite types (`FullName`/`Emails`/`Phones`) route by vault name — they
  carry the resource abbrev but NO `pii_` column prefix (vision doc §core
  "PII routing note"). The verifiers key on the `pii do` declaration, not the
  column-name pattern.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Catalog]

  attributes do
    # Non-PII fields the CRM person carries from the core shape.
    attribute(:job_title, :string, public?: true)

    # Tier-1 jsonb bag — per-org custom fields at the bottom rung of the ladder.
    attribute(:custom, :map, public?: true)
  end

  pii do
    # Three composite vaults: full_name → pii_name, emails → pii_email,
    # phones → pii_phone. Composite types route by vault name (no pii_ prefix).
    vault(:pii_name)
    vault(:pii_email)
    vault(:pii_phone)

    pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)
    pii_attribute(:phones, Samen.Type.Phones, vault: :pii_phone)
  end
end
