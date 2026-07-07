defmodule Samen.Context.Info do
  @moduledoc """
  Introspection surface for the `context` DSL section (T3.10 (c)).

  A bounded context is introspectable — the catalog (and any LLM-grounding
  artifact) can read the whole context map: what kernel nouns were renamed, and
  what derived fields were added by a reshape.

  ## Representation (the T3.10 (c) decision, documented)

  Two first-class lists plus a flattened catalog view:

    * `aliases/1`  — `[%{alias: Name, resource: Kernel}]`, one per `alias_resource`.
    * `reshapes/1` — `[%{resource: Kernel, calculations: [%{name:, type:, …}]}]`.
    * `catalog_context_map/1` — a flat, machine-readable map of the whole context
      map. Alias renames name a kernel TABLE; reshape calcs name a *context-derived
      field* keyed to a kernel table — NEVER a physical `fld_field` column (a reshape
      mints no column). This is the surface the catalog uses to teach the LLM the
      vertical's ubiquitous language without pretending a derived field is storage.
  """

  alias Spark.Dsl.Extension

  @doc "Every `alias_resource` mapping in the context."
  @spec aliases(module()) :: [%{alias: module(), resource: module()}]
  def aliases(context) do
    context
    |> Extension.get_entities([:context])
    |> Enum.filter(&match?(%Samen.Context.Alias{}, &1))
    |> Enum.map(fn %Samen.Context.Alias{resource: resource, as: as} ->
      %{alias: as, resource: resource}
    end)
  end

  @doc "Every `reshape` block in the context, with its declared calculations."
  @spec reshapes(module()) :: [%{resource: module(), calculations: [map()]}]
  def reshapes(context) do
    context
    |> Extension.get_entities([:context])
    |> Enum.filter(&match?(%Samen.Context.Reshape{}, &1))
    |> Enum.map(fn %Samen.Context.Reshape{resource: resource, calculations: calcs} ->
      %{resource: resource, calculations: Enum.map(calcs, &calc_view/1)}
    end)
  end

  @doc """
  The reshape calculation entries (`%Samen.Context.Calculation{}` structs, with
  the raw quoted `expr`) declared against a specific kernel `resource`. Used by
  `Samen.Context.load_reshape/3` to replay each expression at query time.
  """
  @spec calculations_for(module(), module()) :: [Samen.Context.Calculation.t()]
  def calculations_for(context, resource) do
    context
    |> Extension.get_entities([:context])
    |> Enum.filter(&match?(%Samen.Context.Reshape{resource: ^resource}, &1))
    |> Enum.flat_map(& &1.calculations)
  end

  @doc "The context's declared Ash domain, or nil."
  @spec domain(module()) :: module() | nil
  def domain(context) do
    Extension.get_opt(context, [:context], :domain, nil)
  end

  @doc """
  The flattened, machine-readable context map for the catalog / LLM grounding.

  Shape:

      %{
        context: Lumen.Context,
        domain: Lumen.Clinical,
        aliases: [%{alias_name: "Lumen.Encounter", kernel_resource: "Core.Activity",
                    kernel_table: "act_activity"}],
        derived_fields: [%{context_field: "patient_responsibility",
                           kernel_resource: "Core.Invoice", kernel_table: "inv_invoice",
                           type: "decimal", physical?: false}]
      }

  `physical?: false` is explicit and load-bearing: a reshape field is derived, not
  stored — it is NOT a `fld_field` row. The catalog reads this to distinguish a
  context-derived field from a physical column.
  """
  @spec catalog_context_map(module()) :: map()
  def catalog_context_map(context) do
    %{
      context: inspect(context),
      domain: inspect(domain(context)),
      aliases:
        Enum.map(aliases(context), fn %{alias: as, resource: resource} ->
          %{
            alias_name: inspect(as),
            kernel_resource: inspect(resource),
            kernel_table: safe_table(resource)
          }
        end),
      derived_fields:
        Enum.flat_map(reshapes(context), fn %{resource: resource, calculations: calcs} ->
          Enum.map(calcs, fn calc ->
            %{
              context_field: to_string(calc.name),
              kernel_resource: inspect(resource),
              kernel_table: safe_table(resource),
              type: type_string(calc.type),
              physical?: false
            }
          end)
        end)
    }
  end

  defp calc_view(%Samen.Context.Calculation{name: name, type: type, expr: expr}) do
    %{name: name, type: type, resolved_type: Samen.Context.resolve_type(type), expr: expr}
  end

  defp safe_table(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  defp type_string(:money), do: "decimal"
  defp type_string(type) when is_atom(type), do: type |> inspect() |> String.trim_leading("Ash.Type.")
  defp type_string(type), do: inspect(type)
end
