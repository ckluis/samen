defmodule Samen.Catalog.MeaningField do
  @moduledoc """
  One `field :name, label: …, synonyms: […], units: …` entry of a resource's `meaning do … end` section
  (`Samen.Catalog`). The attribute's description is NOT here: it stays on the Ash attribute.
  """
  defstruct [:name, :label, :units, synonyms: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          label: String.t() | nil,
          synonyms: [String.t()],
          units: String.t() | nil,
          __spark_metadata__: term()
        }
end
