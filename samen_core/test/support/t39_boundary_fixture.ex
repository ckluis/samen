defmodule SamenCore.T39Boundary.Offender do
  @moduledoc """
  T3.9 boundary test fixture — a resource that DECLARES a relationship into
  `Samen.CustomObjects.Record` (`tnt_record`), i.e. a system resource reaching
  INTO the tenant regime, which the one-way boundary forbids.

  It is a PLAIN `Ash.Resource` (NOT `use Samen.Resource`) on purpose: were it a
  Samen resource, the compile-time `Samen.Verifiers.TntBoundary` verifier would
  (correctly) fail the build and this fixture could never compile. Keeping it a
  plain Ash resource lets the whole-app *sweep* test exercise the same detection
  logic (`Ash.Resource.Info.relationships/1` → destination == Record) against a
  real relationship declaration, WITHOUT this fixture short-circuiting the build.

  The anti-tautology probe for the compile-time verifier is documented separately
  in the T3.9 report: a `use Samen.Resource` resource with the same relationship is
  written into a scratch dir, confirmed to FAIL compile with the boundary
  diagnostic, then reverted.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
  end

  relationships do
    # THE VIOLATION: a system resource pointing INTO the tenant regime.
    belongs_to(:offending, Samen.CustomObjects.Record) do
      public?(true)
      attribute_type(:uuid)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
