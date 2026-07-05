defmodule Samen.Pii.Vault do
  @moduledoc """
  A `vault :name` declaration inside a `pii do … end` block.

  Declaring a vault names a valid routing target. A `pii_attribute` may only route
  to a vault that has been declared — an undeclared vault is a compile error
  (`Samen.Pii.Verifiers.VaultDeclared`). This makes vault routing *closed*: you
  cannot fat-finger `vault: :pii_naem` and silently get a field that routes
  nowhere. The vault runtime (the actual `pii_*` table + ciphertext + tokens) is
  T1.4; here the declaration is what downstream verifiers and the T1.4/T1.5
  runtime key on.
  """
  defstruct [:name, :label, __spark_metadata__: nil]

  @type t :: %__MODULE__{name: atom(), label: String.t() | nil, __spark_metadata__: term()}
end

defmodule Samen.Pii.Attribute do
  @moduledoc """
  A single `pii_attribute :field, Type, vault: :pii_name` declaration inside a
  `pii do … end` block (vision doc §core PII routing note; plan D2).

  ## Storage naming — routes by DECLARATION, keyed by type shape

  Both composite and scalar `pii_attribute`s are vault-routed. They differ ONLY
  in the physical column name (vision doc §core "PII routing note"):

    * **Composite** fields (`Samen.Type.FullName/Emails/Phones`) route *by vault
      name*, so they carry the resource abbrev but **no** `pii_` column prefix:
      `full_name` → `per_full_name`.
    * **Scalar** `pii_attribute` fields carry the `pii_` prefix:
      `dob` → `pii_pat_dob`, `cdl_number` → `pii_drv_cdl_number`.

  Both are equally vault-routed. Downstream verifiers (C3 `pii_reads`,
  C5 `no_plaintext_pii`) key on THIS declaration (the `pii do` block + the vault
  routing), never on whether the storage column happens to carry a `pii_` prefix.
  The prefix is a storage convention; the declaration is the truth.

  ## Scope note (T1.3)

  At T1.3 a `pii_attribute` is still *materialized as a real Ash attribute* (see
  `Samen.Transformers.MaterializePii`) so it gets a physical column the abbrev
  transformer prefixes per the routing rule above. The full vault split
  (`pii_*` table + ciphertext + FK token, `%Masked{}` as the normal value) is
  T1.4/T1.5. T1.3 lands the DSL, the composite types, the classification registry,
  the storage-naming split, and the introspection API the vault runtime consumes.
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
  Spark DSL extension carrying the `pii do … end` section — the real vault-routing
  DSL (plan D2; T1.3). Ported and productionized from the S0.3 stub (S0.3's `pii`
  section materialized a plain `sensitive?: true` column; this is the real one).

      pii do
        vault :pii_name
        vault :pii_email
        vault :pii_dob

        pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name
        pii_attribute :emails,    Samen.Type.Emails,   vault: :pii_email
        pii_attribute :dob,       :date,               vault: :pii_dob
      end

  ## What this extension provides

    * The `pii` section with `vault` and `pii_attribute` entities.
    * `Samen.Pii.Verifiers.VaultDeclared` — a compile-time Spark verifier that
      FAILS compile if a `pii_attribute` routes to a vault that was never declared
      (the T1.3 red path: "declaring a vault on a non-existent vault table fails
      compile"). Closed-world vault routing: no silent typo'd routes.
    * `Samen.Transformers.MaterializePii` — materializes each `pii_attribute` into
      a real column with the correct storage name (composite ⇒ `<abbrev>_<name>`,
      scalar ⇒ `pii_<abbrev>_<name>`).

  A `Spark.Dsl.Fragment` may declare this extension to place a `pii` block that
  folds into the composing resource; folded PII columns inherit the composing
  resource's abbrev.

  ## Introspection

  `Samen.Pii.Info` exposes the vault-routed attributes per resource, their vaults,
  and their storage names — the list the T1.4 vault runtime and the C3/C5
  verifiers consume.
  """

  @vault %Spark.Dsl.Entity{
    name: :vault,
    describe: "Declares a valid vault routing target. A pii_attribute may only route to a declared vault.",
    target: Samen.Pii.Vault,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The vault name, e.g. :pii_name."],
      label: [type: :string, required: false, doc: "Optional human label for the vault."]
    ]
  }

  @pii_attribute %Spark.Dsl.Entity{
    name: :pii_attribute,
    describe: "Declares a vault-routed PII field. Composite types route by vault name (no pii_ prefix); scalars carry the pii_ prefix.",
    target: Samen.Pii.Attribute,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true],
      type: [type: :any, required: true],
      vault: [type: :atom, required: true, doc: "The declared vault this field routes to."],
      storage_type: [
        type: :atom,
        required: false,
        doc: "Physical column type for the T1.3 materialization (defaults from the declared type)."
      ]
    ]
  }

  @pii %Spark.Dsl.Section{
    name: :pii,
    describe: "PII routing declarations. Each field routes to a declared vault.",
    entities: [@vault, @pii_attribute]
  }

  use Spark.Dsl.Extension,
    sections: [@pii],
    transformers: [Samen.Transformers.MaterializePii],
    verifiers: [Samen.Pii.Verifiers.VaultDeclared]
end
