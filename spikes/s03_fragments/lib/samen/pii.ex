defmodule Samen.Pii.Attribute do
  @moduledoc """
  A single `pii_attribute` declaration inside a `pii do … end` block.

  The doc's canonical shape is:

      pii do
        pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name
        pii_attribute :dob, :date, vault: :pii_dob
      end

  For the S0.3 spike a `pii_attribute` is *materialized as a real Ash attribute*
  (see `Samen.Transformers.MaterializePii`) so it gets a physical column that the
  abbrev transformer then prefixes with the composing resource's abbrev. The full
  vault/ciphertext/token machinery is S0.5's job — here we only need the DSL
  section to cross the fragment boundary and produce columns that inherit the
  right prefix.
  """
  defstruct [:name, :type, :vault, :storage_type, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          vault: atom(),
          storage_type: atom(),
          __spark_metadata__: term()
        }
end

defmodule Samen.Pii do
  @moduledoc """
  Spark DSL extension carrying the `pii do … end` section.

  This is the "pii-like section stub" the S0.3 task asks for: it is a real Spark
  extension (with its own section + entity + transformer) so that a
  `Spark.Dsl.Fragment` can declare `extensions: [Samen.Pii]` and put a `pii`
  block in it, and so the composing resource must *also* carry `Samen.Pii` for
  that block to be legal. That "the fragment declares the extension whose DSL it
  uses, and the composing resource must provide it" is the exact rule the S0.3
  RED PATH exercises.

  The transformer materializes each `pii_attribute` into an ordinary attribute
  so it becomes a physical column, then `Samen.Transformers.AbbrevStorage`
  prefixes it with the *composing* resource's abbrev (a fragment `pii_attribute`
  named `:full_name` lands as `pat_full_name` on Patient, `stf_full_name` on
  Staff). Full vault routing/crypto is out of scope for S0.3 (it is S0.5).
  """

  @pii_attribute %Spark.Dsl.Entity{
    name: :pii_attribute,
    describe: "Declares a vault-routed PII field (materialized as a real column for S0.3).",
    target: Samen.Pii.Attribute,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true],
      type: [type: :any, required: true],
      vault: [type: :atom, required: true],
      storage_type: [
        type: :atom,
        required: false,
        doc: "Physical column type for the spike stub (defaults to :string)."
      ]
    ]
  }

  @pii %Spark.Dsl.Section{
    name: :pii,
    describe: "PII routing declarations. Each field routes to a named vault.",
    entities: [@pii_attribute]
  }

  use Spark.Dsl.Extension,
    sections: [@pii],
    transformers: [Samen.Transformers.MaterializePii]
end
