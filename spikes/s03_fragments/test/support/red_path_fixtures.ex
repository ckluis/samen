defmodule Samen.Audit do
  @moduledoc """
  A Samen extension that `Samen.Resource` deliberately does NOT provide.

  Used only by the RED PATH: a fragment declaring `extensions: [Samen.Audit]`
  asks the composing resource for a capability the base macro never wired. That
  must fail the composing resource's compile.
  """
  use Spark.Dsl.Extension
end

defmodule RedPathFixtures.RogueFragment do
  @moduledoc """
  A fragment that declares an extension (`Samen.Audit`) the base macro does not
  provide. Composing it via `use Samen.Resource, base: RedPathFixtures.RogueFragment`
  must raise at compile time (S0.3 RED PATH).

  Compiled here (in support) so the red-path test only has to attempt to compile
  the *composing resource*, which is the fail-closed boundary under test.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Audit]

  attributes do
    attribute(:note, :string, public?: true)
  end
end

defmodule RedPathFixtures.GoodFragment do
  @moduledoc """
  Control fragment: declares ONLY provided extensions. Composing it must succeed
  — this proves the red path fails for the *right* reason (the unprovided
  extension), not because fragment composition is broken in general.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Catalog]

  attributes do
    attribute(:note, :string, public?: true)
  end
end
