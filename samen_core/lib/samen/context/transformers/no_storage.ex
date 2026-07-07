defmodule Samen.Context.Transformers.NoStorage do
  @moduledoc """
  Compile-time guard: **a reshape cannot touch storage** (T3.10 red path).

  A `reshape` adds *derived* calculations over the kernel resource's existing
  columns — it must never mint a physical column, shadow one, or reach into the
  raw abbrev-prefixed storage layer. This transformer fails the context's compile
  (a `Spark.Error.DslError` at the context module) when a reshape calc:

    1. **Names a field that already physically exists** on the kernel resource —
       either a logical attribute name or its abbrev-prefixed storage `source`
       (e.g. reshaping `Core.Invoice` with `calculate :total, …` or
       `calculate :inv_total, …`). A reshape may only ADD a derived field; it may
       not redefine or shadow a stored column.

    2. **References a raw storage column name in its `expr`** — an abbrev-prefixed
       name like `inv_total`. A reshape expression addresses the kernel resource's
       *logical* fields (`total`, `covered_amount`); reaching for the physical
       `<abbrev>_<name>` storage name is touching storage and is refused. (The
       logical→physical mapping is the substrate's self-qualifying-storage idiom;
       the context must not bypass it.)

  The DSL shape is the first line of defence: `reshape` exposes only `calculate`
  (no `attribute`, `relationship`, or `postgres` entity), so a reshape *cannot
  express* a physical column declaration syntactically. This transformer is the
  fail-closed backstop for the two ways a calc could still smuggle storage in
  (a colliding name, or a raw-storage-name expr ref).
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def transform(dsl_state) do
    context_module = Transformer.get_persisted(dsl_state, :module)

    dsl_state
    |> Transformer.get_entities([:context])
    |> Enum.filter(&match?(%Samen.Context.Reshape{}, &1))
    |> Enum.each(&verify_reshape!(&1, context_module))

    {:ok, dsl_state}
  end

  defp verify_reshape!(%Samen.Context.Reshape{resource: resource, calculations: calcs}, context) do
    {logical, physical} = kernel_field_names(resource)

    Enum.each(calcs, fn %Samen.Context.Calculation{name: name, expr: expr} ->
      # (1) name may not collide with a stored column (logical OR physical source).
      if name in logical or Atom.to_string(name) in physical do
        raise DslError,
          module: context,
          path: [:context, :reshape, resource, :calculate, name],
          message:
            "reshape #{inspect(resource)}: `calculate #{inspect(name)}` collides with a " <>
              "physical column of the kernel resource. A reshape may only ADD a derived " <>
              "field — it cannot touch storage by redefining or shadowing a stored column. " <>
              "Rename the derived field."
      end

      # (2) expr may not reference a raw abbrev-prefixed storage name.
      offending = storage_refs_in(expr, physical)

      unless offending == [] do
        raise DslError,
          module: context,
          path: [:context, :reshape, resource, :calculate, name],
          message:
            "reshape #{inspect(resource)}: `calculate #{inspect(name)}` references raw " <>
              "storage column(s) #{inspect(offending)} in its expression. A reshape addresses " <>
              "the kernel resource's LOGICAL fields (the self-qualifying-storage idiom maps " <>
              "them to physical columns); reaching for the physical `<abbrev>_<name>` name is " <>
              "touching storage and is refused. Use the logical field name."
      end
    end)
  end

  # Logical attribute names (atoms) and physical storage sources (strings) of the
  # kernel resource. A resource that is not (yet) an Ash resource yields empty sets
  # — the DSL-shape guard still holds; this transformer just adds nothing.
  defp kernel_field_names(resource) do
    attrs =
      try do
        Ash.Resource.Info.attributes(resource)
      rescue
        _ -> []
      end

    logical = Enum.map(attrs, & &1.name)
    physical = Enum.map(attrs, fn a -> to_string(a.source || a.name) end)
    {logical, physical}
  end

  # Collect field references in the (evaluated) Ash expression that name a physical
  # storage column of the kernel resource. Ash represents a field ref as an
  # `%Ash.Query.Ref{attribute: name}` node; we walk the whole expression tree and
  # keep any `attribute` matching a physical `<abbrev>_<name>` storage name.
  defp storage_refs_in(expr, physical) do
    physical_set = MapSet.new(physical)

    expr
    |> collect_ref_names([])
    |> Enum.filter(&(to_string(&1) in physical_set))
    |> Enum.uniq()
  end

  defp collect_ref_names(%Ash.Query.Ref{attribute: attr} = node, acc) do
    name = ref_attr_name(attr)
    acc = if name, do: [name | acc], else: acc
    # A Ref can carry nested structure; still descend its other fields.
    node |> Map.from_struct() |> Map.delete(:attribute) |> Map.values() |> collect_ref_names(acc)
  end

  defp collect_ref_names(%_{} = struct, acc) do
    struct |> Map.from_struct() |> Map.values() |> collect_ref_names(acc)
  end

  defp collect_ref_names(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_ref_names/2)
  end

  defp collect_ref_names(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect_ref_names(acc)
  end

  defp collect_ref_names(map, acc) when is_map(map) do
    map |> Map.values() |> collect_ref_names(acc)
  end

  defp collect_ref_names(_leaf, acc), do: acc

  defp ref_attr_name(attr) when is_atom(attr), do: attr
  defp ref_attr_name(%{name: name}), do: name
  defp ref_attr_name(_), do: nil
end
