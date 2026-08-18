defmodule Samen.Fleet.Assignment.Blueprint do
  @moduledoc """
  Resource-definition macro for the **operator-account assignment** resource
  (ADR-044 §16.5 #1, ruling R-A) — the `*_assignment` table one operator×product×
  account grant per row.

  `use Samen.Aggregate.Resource` (not `Samen.Resource`) so the C7
  `Samen.Verifiers.NoPiiColumns` compile check runs: a `pii_attribute`, a `vault`
  block, a `pii_`-shaped column, or a relationship reaching a PII-bearing resource
  fails the build (INV-2 by construction). Every column here is a bounded scalar
  (`operator_id`/`account_org_id` uuids, `app_scope` a bounded lowercase slug) — no
  tenant identity, no name, no PII.

  Like the fleet registry (`Samen.Fleet.Scope.Blueprint`), `org_id` is an explicit
  NULLABLE override — this is operator-owned cross-tenant governance data, NOT a
  tenant-plane resource, so it opts OUT of the universal non-null `org_id` injection.
  The *account* being granted is `account_org_id` (a distinct column), never `org_id`.
  """

  # ---------------------------------------------------------------------------
  # *_assignment — one operator × app_scope × account grant (§16.5 #1)
  # ---------------------------------------------------------------------------
  defmacro define_assignment(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `#{unquote(abbrev)}_assignment` — one operator-to-account grant (ADR-044
        §16.5 #1, ruling R-A). A row `(operator_id, app_scope, account_org_id)` means
        *this operator is scoped to this tenant account in this product*. `scope_of/2`
        reads all rows for `(operator_id, app_scope)` into a `{:accounts, MapSet}`;
        absent any row it returns `:none` (fail-closed by absence).

        `account_org_id` is the GRANTED tenant account (never `org_id`, which stays
        nil — this resource opts out of tenant-plane org scoping like the fleet
        registry). `app_scope` is the product slug (a bounded lowercase atom-slug),
        the same J3 product-scope carrier `:operator_authority`/`:fleet_resolution`
        thread (§6.2). Token-blind: no name, no PII (INV-2, NoPiiColumns).
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_assignment")
          repo(unquote(repo))
        end

        attributes do
          # Opt OUT of tenant-plane org scoping — operator-owned cross-tenant data.
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:operator_id, :uuid, public?: true, allow_nil?: false)

          # The product slug (a bounded lowercase atom-slug, e.g. "driftwood") — the
          # J3 product-scope carrier, never producer/tenant-chosen free text.
          attribute(:app_scope, :string,
            public?: true,
            allow_nil?: false,
            constraints: [match: ~r/\A[a-z][a-z0-9_]{0,39}\z/]
          )

          # The GRANTED tenant account org id (a bounded uuid; NOT tenant PII).
          attribute(:account_org_id, :uuid, public?: true, allow_nil?: false)
        end

        identities do
          # One grant per (operator, product, account) — a re-grant is idempotent,
          # not a duplicate row. Also the concurrency guard against a double-insert.
          identity(:unique_grant, [:operator_id, :app_scope, :account_org_id])
        end

        actions do
          defaults([:read, :destroy, create: :*])
        end

        policies do
          # Minimal admin surface: only an operator-admin may create/revoke/read
          # assignments. The scope_of/2 read path runs authorize?: false (the
          # framework reading its own scope data — next_key_version precedent).
          policy action_type([:create, :destroy, :read]) do
            authorize_if(Samen.Policy.OperatorAdminOnly)
          end
        end
      end
    end
  end
end
