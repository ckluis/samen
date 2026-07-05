defmodule Samen.Catalog do
  @moduledoc """
  Stub of the Samen catalog extension for the S0.3 spike.

  In the real foundry this generates `tam_table`/`fld_field` rows (S0.4, B1–B4).
  For S0.3 it exists only as an extension the `Core.Person` fragment can declare
  (`extensions: [Samen.Pii, Samen.Catalog]`) and that `Samen.Resource` provides
  to every composed resource — so the fragment-declares / resource-must-provide
  contract has a second, no-op extension to exercise it against.

  It carries no sections/transformers of its own here; it is purely a marker
  that the composing resource must include.
  """
  use Spark.Dsl.Extension
end
