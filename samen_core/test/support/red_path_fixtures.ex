defmodule Samen.Audit do
  @moduledoc """
  A Samen-namespace extension that `Samen.Resource` deliberately does NOT provide.

  Used only by the RED PATH: a fragment declaring `extensions: [Samen.Audit]` asks
  the composing resource for a capability the base macro never wired. That must
  fail the composing resource's compile (Gate-0 fix task #3).
  """
  use Spark.Dsl.Extension
end

defmodule SamenCore.RedPathFixtures.RogueFragment do
  @moduledoc """
  A fragment declaring an un-provided Samen extension (`Samen.Audit`). Composing it
  via `use Samen.Resource, base: ...` must raise at compile time.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Audit]

  attributes do
    attribute(:note, :string, public?: true)
  end
end

defmodule SamenCore.RedPathFixtures.GoodFragment do
  @moduledoc """
  Control fragment: declares ONLY provided extensions. Composing it must succeed —
  proving the red path fails for the right reason (the unprovided extension), not
  because fragment composition is broken in general.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Catalog]

  attributes do
    attribute(:note, :string, public?: true)
  end
end
