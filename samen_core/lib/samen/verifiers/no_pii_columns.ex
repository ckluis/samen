defmodule Samen.Verifiers.NoPiiColumns do
  @moduledoc """
  Compile-time Spark verifier enforcing the **token-blind aggregate plane** invariant
  (C7; plan T4.2 clause (b); doc §control "an aggregate actor … whose resources have
  **no pii_ columns at all**" / "a vault-excluded projection where pii_ columns
  physically don't exist").

  ## What it enforces

  It runs ONLY on resources that opted into the aggregate plane (they carry
  `Samen.Aggregate.Extension`, which lists this verifier — see
  `Samen.Aggregate.Resource`). It is NEVER wired into the base `Samen.Extension`,
  so it can never false-positive on a tenant-plane / operator-plane resource.

  For an aggregate resource it FAILS the build (fail-closed, non-zero compile) when
  the resource:

    1. declares a **`pii_attribute`** in a `pii do` block (a vault-routed field on
       the aggregate plane is a contradiction — the whole point is that no PII is
       reachable);

    2. declares a **`vault`** (routing a field into the PII vault at all);

    3. carries any **physical column** whose storage name matches the vault shape
       `pii_<abbrev>_<name>` (defense in depth — a `pii_`-prefixed column reaching
       the aggregate projection, even one added out-of-band, fails);

    4. declares a **relationship** (`belongs_to`/`has_one`/`has_many`/
       `many_to_many`) whose destination is a **PII-bearing resource** (one that
       declares any `pii_attribute`). A relationship reaching a PII-bearing resource
       would let the aggregate plane traverse INTO vaulted data — closing the
       "vault-excluded projection" by construction, not by convention.

  ## Why compile-time

  The doc's claim is structural: "pii_ columns physically don't exist" on the
  aggregate plane. A runtime policy could be misconfigured; a compile-time verifier
  makes a PII-reaching aggregate resource **not compile**. The whole-app CI backstop
  (`mix samen.verify.no_pii_columns`) sweeps every configured domain for the same
  violations (catching a resource that somehow skipped the extension).
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  # Vault-shaped physical column: pii_<abbrev>_<name>.
  @pii_column_prefix "pii_"

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    case violations(dsl_state, module) do
      [] ->
        :ok

      [{path, message} | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: path,
           message: message
         )}
    end
  end

  @doc """
  Compute the aggregate-plane PII violations for a resource's DSL state (or a
  compiled module). Returns a list of `{path, message}` tuples — empty means clean.
  Separated from `verify/1` so the mix-task backstop can reuse the exact same rules.
  """
  @spec violations(Spark.Dsl.t() | module(), module()) :: [{list(), String.t()}]
  def violations(dsl_state, module) do
    pii_attribute_violations(dsl_state, module) ++
      vault_violations(dsl_state, module) ++
      pii_column_violations(dsl_state, module) ++
      pii_relationship_violations(dsl_state, module)
  end

  # (1) any declared pii_attribute
  defp pii_attribute_violations(dsl_state, module) do
    case Samen.Pii.Info.pii_attributes(dsl_state) do
      [] ->
        []

      attrs ->
        names = Enum.map(attrs, & &1.name)

        [
          {[:pii],
           "aggregate-plane resource #{inspect(module)} declares pii_attribute(s) " <>
             "#{inspect(names)}. The token-blind aggregate plane must have NO PII — its " <>
             "resources project only vault-excluded, non-PII columns (counts, rollups). " <>
             "Remove the pii_attribute (C7, plan T4.2; doc §control)."}
        ]
    end
  end

  # (2) any declared vault (routing a field into the PII vault)
  defp vault_violations(dsl_state, module) do
    case Samen.Pii.Info.vaults(dsl_state) do
      [] ->
        []

      vaults ->
        [
          {[:pii],
           "aggregate-plane resource #{inspect(module)} declares vault(s) " <>
             "#{inspect(vaults)}. An aggregate-plane resource must not route ANY field " <>
             "into the PII vault — pii_ columns physically don't exist here (C7, T4.2)."}
        ]
    end
  end

  # (3) any physical column carrying the pii_ vault-shape prefix (defense in depth)
  defp pii_column_violations(dsl_state, module) do
    dsl_state
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr -> to_string(attr.source || attr.name) end)
    |> Enum.filter(&String.starts_with?(&1, @pii_column_prefix))
    |> case do
      [] ->
        []

      cols ->
        [
          {[:attributes],
           "aggregate-plane resource #{inspect(module)} carries physical column(s) " <>
             "#{inspect(cols)} matching the vault shape `pii_*`. The aggregate plane's " <>
             "projection must contain no pii_ columns at all (C7, T4.2)."}
        ]
    end
  end

  # (4) a relationship whose destination is a PII-bearing resource
  defp pii_relationship_violations(dsl_state, module) do
    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(fn rel -> pii_bearing?(rel.destination) end)
    |> Enum.map(fn rel ->
      {[:relationships, rel.name],
       "aggregate-plane resource #{inspect(module)} declares relationship " <>
         "#{inspect(rel.name)} → #{inspect(rel.destination)}, which is a PII-bearing " <>
         "resource (it declares pii_attribute(s)). A relationship reaching a PII-bearing " <>
         "resource would let the aggregate plane traverse INTO vaulted data — the " <>
         "vault-excluded projection forbids it (C7, T4.2). Remove the relationship."}
    end)
  end

  # A destination resource is PII-bearing if it declares any pii_attribute. Guard
  # against a not-yet-compiled destination (relationship destinations can be defined
  # later in compile order) — treat an unresolvable destination as non-PII here; the
  # whole-app mix-task backstop re-checks against fully compiled modules.
  defp pii_bearing?(destination) when is_atom(destination) do
    with {:module, ^destination} <- Code.ensure_compiled(destination),
         true <- function_exported?(destination, :spark_dsl_config, 0) do
      Samen.Pii.Info.pii_attributes(destination) != []
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp pii_bearing?(_), do: false
end
