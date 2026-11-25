defmodule Samen.AI.VtSentinel do
  @moduledoc """
  The vault FK-token sentinel predicate (`vt_*`; `Samen.Vault.generate_token/0` mints `"vt_" <> 32hex`), in ONE place.

  `Samen.AI.Chokepoint` refuses any rendered string for which `in_string?/1` is true (the PREFIX substring, not the
  anchored token shape: a token laundered mid-string must be refused too). The compile-time meaning check
  (`Samen.Catalog.Transformers.MeaningDeclarations`) calls the SAME function, so authored catalog text the chokepoint
  would refuse can never compile. A leaf module with no dependencies, so a resource's transformer can call it while
  the kernel is still compiling.
  """

  @sentinel "vt_"

  @doc "The sentinel literal."
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc "Whether `string` carries the vault-token sentinel anywhere (case-sensitive, like the chokepoint's scrub)."
  @spec in_string?(String.t()) :: boolean()
  def in_string?(string) when is_binary(string), do: String.contains?(string, @sentinel)

  @doc """
  Every string leaf of `term` (map keys AND values, list elements) as `{path, string}`. A test asserts
  `leaves(catalog) |> Enum.filter(&in_string?/1)` is empty for a host's whole catalogue, whichever channel a string
  arrived by (description, label, synonym, unit, allowed value, name).
  """
  @spec leaves(term()) :: [{[term()], String.t()}]
  def leaves(term), do: leaves([], term)

  defp leaves(path, string) when is_binary(string), do: [{Enum.reverse(path), string}]

  defp leaves(path, map) when is_map(map) and not is_struct(map) do
    Enum.flat_map(map, fn {key, value} ->
      key_leaf = if is_binary(key), do: [{Enum.reverse([key | path]), key}], else: []
      key_leaf ++ leaves([key | path], value)
    end)
  end

  defp leaves(path, list) when is_list(list), do: Enum.flat_map(list, &leaves(path, &1))
  defp leaves(_path, _other), do: []
end
