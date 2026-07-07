defmodule Samen.Aggregate.Resource do
  @moduledoc """
  Declare a **token-blind aggregate-plane resource** (T4.2 clause (a)+(c); doc
  §control "an aggregate actor … reading a vault-excluded projection where pii_
  columns physically don't exist").

  This is `use Samen.Resource` PLUS the aggregate marker + the compile-time C7
  `NoPiiColumns` verifier. Everything `Samen.Resource` gives you (self-qualifying
  storage, catalog, universal columns) still applies; on top:

    * the resource is marked `aggregate_plane: true` (introspectable via
      `Samen.Aggregate.Info.aggregate_plane?/1`);

    * `Samen.Verifiers.NoPiiColumns` runs at COMPILE time and FAILS the build if the
      resource declares a `pii_attribute`, a `vault`, a `pii_`-shaped physical
      column, or a relationship reaching a PII-bearing resource. So an aggregate
      resource that could reach vaulted PII does not compile.

  ## Usage

      defmodule MyApp.Aggregate.MrrByTier do
        use Samen.Aggregate.Resource,
          otp_app: :my_app,
          domain: MyApp.Aggregate,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: "amr"

        postgres do
          table("rol_mrr_by_tier")   # a vault-excluded rollup/summary table
          repo(MyApp.Repo)
        end

        attributes do
          attribute(:tier, :string, public?: true)      # bounded enum, non-PII
          attribute(:mrr_cents, :integer, public?: true) # a count/number, non-PII
          attribute(:tenant_count, :integer, public?: true)
        end

        actions do
          defaults([:read])   # aggregate resources are read-only projections
        end

        # DEFAULT DENY — only the token-blind aggregate actor is admitted (T4.2).
        policies do
          policy always() do
            authorize_if(Samen.Policy.AggregateActorOnly)
          end
        end
      end

  The resource reads a **vault-excluded projection** — a `rol_*`/summary table that
  physically has no `pii_` columns (asserted via `information_schema` in the T4.2
  tests). It NEVER `belongs_to` a PII-bearing resource; the C7 verifier refuses that
  at compile time.
  """

  @doc false
  defmacro __using__(opts) do
    {extensions, opts} = Keyword.pop(opts, :extensions, [])

    opts =
      Keyword.put(
        opts,
        :extensions,
        Enum.uniq([Samen.Aggregate.Extension | List.wrap(extensions)])
      )

    quote do
      use Samen.Resource, unquote(opts)
    end
  end
end
