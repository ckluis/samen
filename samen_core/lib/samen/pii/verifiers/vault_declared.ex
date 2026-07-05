defmodule Samen.Pii.Verifiers.VaultDeclared do
  @moduledoc """
  Compile-time Spark verifier enforcing **closed-world vault routing** (T1.3 red
  path: "pii_attribute referencing an undeclared vault fails compile").

  Every `pii_attribute :field, Type, vault: :v` must route to a vault the same
  `pii do` block declared with `vault :v`. Routing to a vault that was never
  declared — the fat-fingered `vault: :pii_naem`, or a field pointed at a vault
  table that does not exist — is a `Spark.Error.DslError` at compile time, not a
  silent field that routes nowhere.

  This is the T1.3-level analogue of "a hallucinated field doesn't compile": a
  hallucinated *vault* doesn't compile either. The vault runtime (the physical
  `pii_*` table) is T1.4; the *declaration* is what closes the world here, and
  T1.4 binds each declared vault to its table.

  ## Why a verifier and not just a transformer check

  Spark verifiers run after all transformers, over the fully-folded DSL — so a
  vault declared in a fragment's `pii do` block and a `pii_attribute` declared on
  the composing resource are both visible here. Verifiers are also the phase Spark
  reliably fails the build on `DslError`, giving the fail-closed guarantee.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    declared_vaults =
      dsl_state
      |> Verifier.get_entities([:pii])
      |> Enum.filter(&match?(%Samen.Pii.Vault{}, &1))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    attributes =
      dsl_state
      |> Verifier.get_entities([:pii])
      |> Enum.filter(&match?(%Samen.Pii.Attribute{}, &1))

    case Enum.filter(attributes, fn attr -> not MapSet.member?(declared_vaults, attr.vault) end) do
      [] ->
        :ok

      [%Samen.Pii.Attribute{name: name, vault: vault} | _] = offenders ->
        module = Verifier.get_persisted(dsl_state, :module)
        offender_names = Enum.map(offenders, & &1.name)

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:pii, :pii_attribute, name],
           message:
             "pii_attribute #{inspect(name)} routes to vault #{inspect(vault)}, which is " <>
               "not declared in this resource's `pii do` block. Every vault a " <>
               "pii_attribute routes to must be declared with `vault #{inspect(vault)}` " <>
               "(closed-world routing: no silent typo'd or non-existent vault). " <>
               "Declared vaults: #{inspect(MapSet.to_list(declared_vaults))}. " <>
               "Offending attribute(s): #{inspect(offender_names)}."
         )}
    end
  end
end
