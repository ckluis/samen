defmodule Samen.WebTest.RichTypes do
  @moduledoc """
  ADR-036 H7 (T15 done-criteria 3/4): the samen_web test-support domain proving
  that `Samen.Catalog.fields/1`, the per-plane masked render, and `Samen.Web.Csv`
  honor EVERY H1-H4 rich type "by construction" (ADR-036 §3 H7's own claim) —
  once the D5 clauses T12/T13/T14 landed exist, the catalog/CSV/masking surfaces
  need no per-type code; this fixture is the proof, not new plumbing.

  Fresh `rti` abbrev (`mix samen.abbrev.reserve --host samen_web --abbrev rti
  --owner Samen.WebTest.RichTypes.Item`), mirroring how `Samen.WebTest.Crm`/
  `Samen.WebTest.RichTypes.PersonalFixture` (samen_core) reserve their own.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.WebTest.RichTypes.Item)
  end
end

defmodule Samen.WebTest.RichTypes.Item do
  @moduledoc """
  ONE resource carrying every ADR-036 H1-H4 rich type, split the SAME way T13's
  `SamenCore.Support.RichTypes` fixtures split (org-level plain vs. personal
  vaulted), so the round-trip matrix test can exercise BOTH masking postures in
  one place, against the REAL samen_web CSV/masking machinery (not just the
  samen_core type-level cast contract T13/T14 already proved):

    * PLAIN (non-vaulted) — `money`/`percent`/`score`/`duration`/`priority`/
      `website` — the non-PII-by-type family (ADR-036 D1/D2): catalog dump +
      CSV round-trip proofs; masked render proves these NEVER mask (they are
      not PII, on ANY plane).
    * VAULTED (`pii_attribute`) — `email`/`phone`/`address` — the PII-by-type
      family (ADR-036 D3/D4): CSV round-trip + the FULL `Samen.MaskingCase`
      3-proof (tenant clear / operator `••••` / sabotage twin) — the INV-1
      done-criterion 4 surface, Address at minimum.
    * PLAIN catalog-dump-only twins — `contact_email`/`contact_phone`/
      `mailing_address` — mirror T13/T14's `sro_org_fixture.support_email`/
      `support_phone`/`billing_address`: a VAULTED `pii_attribute` always
      materializes as `Samen.Type.VaultField` (the physical storage type), so
      `Samen.Catalog.fields/1` reports `"Samen.Type.VaultField"` for `email`/
      `phone`/`address` above — that is CORRECT vault-routing behavior, not a
      catalog bug, but it means the "dumps its OWN module name" proof (D5) for
      `EmailAddress`/`PhoneNumber`/`Address` needs a PLAIN column, same as the
      samen_core fixtures already established.
  """
  use Samen.Resource,
    otp_app: :samen_web,
    domain: Samen.WebTest.RichTypes,
    data_layer: AshPostgres.DataLayer,
    abbrev: "rti"

  postgres do
    table("rti_item")
    repo(Samen.WebTest.Repo)
  end

  attributes do
    attribute(:name, :string, public?: true)

    # -- non-PII-by-type (ADR-036 D1/D2): plain, never masked --------------------
    attribute(:money, Samen.Type.Money, public?: true)
    attribute(:percent, Samen.Type.Percent, public?: true)
    attribute(:score, Samen.Type.Score, public?: true)
    attribute(:duration, Samen.Type.Duration, public?: true)
    attribute(:priority, Samen.Type.Priority, public?: true)
    attribute(:website, Samen.Type.URL, public?: true)

    # -- catalog-dump-only twins (see moduledoc) ---------------------------------
    attribute(:contact_email, Samen.Type.EmailAddress, public?: true)
    attribute(:contact_phone, Samen.Type.PhoneNumber, public?: true)
    attribute(:mailing_address, Samen.Type.Address, public?: true)
  end

  pii do
    vault(:pii_email)
    vault(:pii_phone)
    vault(:pii_address)

    # -- PII-by-type (ADR-036 D3/D4): vaulted, masked-by-plane -------------------
    pii_attribute(:email, Samen.Type.EmailAddress, vault: :pii_email)
    pii_attribute(:phone, Samen.Type.PhoneNumber, vault: :pii_phone)
    pii_attribute(:address, Samen.Type.Address, vault: :pii_address)
  end

  preparations do
    prepare(Samen.Api.PiiResolution)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
