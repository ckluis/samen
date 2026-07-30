defmodule Samen.Scopes.Locations.Blueprint do
  @moduledoc """
  Resource-definition macro for the **Locations** scope (F5; spec §F5,
  spec-questions c17).

  One resource: **`Location`** — a physical-place-centric record (site, office,
  warehouse, …) for verticals that need one. Org-scoped, archivable.

  ## `address` — the ADR-036 H4 composite, ALWAYS vaulted (c17 split)

  `Samen.Type.Address` self-classifies `:pii` unconditionally (ADR-036 D4 — no
  `TypeClearance` can override it), so it is declared here exactly like T14's own
  `SamenCore.Support.RichTypes.PersonalFixture` fixture:

      pii do
        vault(:pii_address)
        pii_attribute(:address, Samen.Type.Address, vault: :pii_address)
      end

  Composite routing convention (no `pii_` column prefix): the storage column is
  `<abbrev>_address` (a `Samen.Type.VaultField` `:text` column holding an opaque
  `vt_*` token — never plaintext). Masked per plane through the standard
  `Samen.Api.PiiResolution` seam (INV-1) — never hand-masked here.

  ## No geometry column (ADR-037 §5.10)

  Deliberately no latitude/longitude/PostGIS geometry attribute — `ash_geo` is
  REJECTED substrate-wide (dormant dependency, zero spec requirement; the map
  view rides server-side SVG tiles per M4, not spatial queries). `address` is
  the ONLY location-shaped attribute.

  ## Soft-delete (ADR-040 §5.9)

  `Location` is `archivable: true` (a user-managed noun).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  defmacro define_location(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Locations.Location — a physical-place-centric record (F5): `name` +
        `address` (🔒 vaulted `Samen.Type.Address` composite, `vault: :pii_address`
        — ADR-036 H4/c17). Org-scoped. Archivable (ADR-040 §5.9). No geometry
        column (ADR-037 §5.10 — `ash_geo` REJECT).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_location")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
        end

        pii do
          vault(:pii_address)
          pii_attribute(:address, Samen.Type.Address, vault: :pii_address)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
