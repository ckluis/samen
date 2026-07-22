defmodule SamenCore.Support.RichTypes do
  @moduledoc """
  Test fixture domain for T13 (ADR-036 H2/H3 rich scalar types): two resources
  proving the two lawful usage shapes the ADR draws for the PII-shaped H3
  scalars (`EmailAddress`/`PhoneNumber`) and the personal-profile URL caveat.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.RichTypes.PersonalFixture)
    resource(SamenCore.Support.RichTypes.OrgFixture)
  end
end

defmodule SamenCore.Support.RichTypes.PersonalFixture do
  @moduledoc """
  Personal-use fixture (ADR-036 D3 for email/phone; the §3 H3 caveat for URL; D4/H4
  for address; H5 for dob): `EmailAddress`/`PhoneNumber`/`URL`/`Address` and a
  scalar `:date` dob declared as VAULTED `pii_attribute`s — the safe default path
  for a natural person's own contact info / profile link / postal address / date
  of birth. Materializes via `Samen.Transformers.MaterializePii`, so each field's
  normal read value is `%Samen.Masked{}` (never plaintext, never a raw `vt_*`
  token).

  `:address` and `:dob` are T14's H4/H5 additions (ADR-036 D4/D5): `:pii_address`
  and `:pii_dob` are new vault CLASSES — per D4 there is no central registry to
  edit, a vault class is exactly this `vault :name` declaration + a `pii_attribute`
  routing to it, so declaring them here IS "registering" pii_address/pii_dob (the
  probe test in `samen_core/test/type/address_test.exs` asserts both are live,
  routable vaults via `Samen.Pii.Info`). `:dob` mirrors the pre-existing
  `SamenCore.Support.Clinical.Patient` `:pii_dob` usage — H5 formalizes the SAME
  recipe inside this task's own fixture domain rather than reaching into a
  different task's fixture.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.RichTypes,
    data_layer: AshPostgres.DataLayer,
    abbrev: "srp"

  postgres do
    table("srp_personal_fixture")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:label, :string, public?: true)
  end

  pii do
    vault(:pii_email)
    vault(:pii_phone)
    vault(:pii_url)
    vault(:pii_address)
    vault(:pii_dob)

    pii_attribute(:email, Samen.Type.EmailAddress, vault: :pii_email)
    pii_attribute(:phone, Samen.Type.PhoneNumber, vault: :pii_phone)
    pii_attribute(:profile_url, Samen.Type.URL, vault: :pii_url)
    pii_attribute(:address, Samen.Type.Address, vault: :pii_address)
    pii_attribute(:dob, :date, vault: :pii_dob)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule SamenCore.Support.RichTypes.OrgFixture do
  @moduledoc """
  Org-level / non-personal fixture (ADR-036 D2, D3's org-contact case): plain
  (NON-vaulted) attributes of every H2/H3 type. This is:

    * the catalog-dump proof resource (done-criterion 4 — one attribute per
      new type, so `Samen.Catalog.fields/1` can be asserted against all seven
      in one place);
    * the Priority-ordering-in-a-read-query fixture (done-criterion 2 — seeded
      rows sorted `priority: :asc` must come back in spec rank order).

  `:support_email`/`:support_phone` are the ORG-CONTACT plaintext use case (a
  company's `support@`/support line) — deliberately left un-vaulted and
  un-cleared so the suite can assert the type-level PII default still applies
  (masked/flagged until a per-column `Samen.NonPii.register/1` clearance
  ships), mirroring the RED-PATH intent of
  `SamenCore.Support.PiiClassify.PersonRecord`.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.RichTypes,
    data_layer: AshPostgres.DataLayer,
    abbrev: "sro"

  postgres do
    table("sro_org_fixture")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true)
    attribute(:percent, Samen.Type.Percent, public?: true)
    attribute(:score, Samen.Type.Score, public?: true)
    attribute(:duration, Samen.Type.Duration, public?: true)
    attribute(:priority, Samen.Type.Priority, public?: true)
    attribute(:website, Samen.Type.URL, public?: true)
    attribute(:support_email, Samen.Type.EmailAddress, public?: true)
    attribute(:support_phone, Samen.Type.PhoneNumber, public?: true)
    # T14 (ADR-036 H4, done-criterion 4): the catalog-dump proof for Address,
    # mirroring support_email/support_phone/website above — a PLAIN (non-vaulted)
    # column of the type so `Samen.Catalog.fields/1` reports the type's OWN module
    # name ("Samen.Type.Address"). `Address` self-classifies :pii UNCONDITIONALLY
    # (D4 — no TypeClearance can override it, unlike email/phone/URL), so this plain
    # column still classifies :pii same as support_email/support_phone; it exists
    # purely to prove the catalog identity, not as a sanctioned org-contact pattern.
    attribute(:billing_address, Samen.Type.Address, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
