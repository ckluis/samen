defmodule Samen.Type.Priority do
  @moduledoc """
  `Samen.Type.Priority` — H2's ordered-enum scalar (ADR-036 D2; WS-H spec §H2;
  ruling c15: "ordered enum `low<normal<high<urgent`, sortable in `Reads`").

  ## Storage shape — stores a RANK, not the atom (the one type whose storage
  differs from its logical shape)

  `storage_type/1` is `:integer`. The physical column holds a **rank**
  (`low => 10, normal => 20, high => 30, urgent => 40`); the type's
  input/read (logical) face is the atom. A stored `:atom` column sorts
  ALPHABETICALLY (`high < low < normal < urgent` — wrong); storing the rank
  makes `sort(priority: :asc)` native and correct in `Ash.read`/`Reads` with no
  computed column, which is exactly what c15 asks for.

  ## Cast — fixed, closed enum

  `cast_input/2` accepts the atom, the enum name as a string, or the raw rank
  integer — and REJECTS anything outside `#{inspect(Keyword.keys([low: 10, normal: 20, high: 30, urgent: 40]))}` (`:error`, never coerced/defaulted).

  ## PII posture — non-PII, cleared (ADR-036 D2; ADR-034 gate)

  A priority is categorically **not** PII. This module self-classifies
  `:non_pii` (`samen_pii_class/0`), and `samen_core` SHIPS the two-distinct-
  party `Samen.NonPii.TypeClearance` entry that governs it.
  """
  use Ash.Type

  @enum [low: 10, normal: 20, high: 30, urgent: 40]
  @rank_to_atom Map.new(@enum, fn {atom, rank} -> {rank, atom} end)

  @doc "Self-classification for `Samen.Pii.Classification`: a priority is non-PII (ADR-036 D2)."
  def samen_pii_class, do: :non_pii

  @impl true
  def storage_type(_constraints), do: :integer

  @impl true
  def constraints, do: []

  @doc "The ordered enum atoms, low → urgent (ranks ascending)."
  @spec values() :: [atom()]
  def values, do: Keyword.keys(@enum)

  @doc "The stored rank for an enum atom, or `nil` if not a member."
  @spec rank(atom()) :: pos_integer() | nil
  def rank(atom) when is_atom(atom), do: Keyword.get(@enum, atom)

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(atom, _constraints) when is_atom(atom) do
    if Keyword.has_key?(@enum, atom), do: {:ok, atom}, else: :error
  end

  def cast_input(rank, _constraints) when is_integer(rank) do
    case Map.fetch(@rank_to_atom, rank) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  def cast_input(str, constraints) when is_binary(str) do
    try do
      cast_input(String.to_existing_atom(str), constraints)
    rescue
      ArgumentError -> :error
    end
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(rank, _constraints) when is_integer(rank) do
    case Map.fetch(@rank_to_atom, rank) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(atom, _constraints) when is_atom(atom) do
    case Keyword.fetch(@enum, atom) do
      {:ok, rank} -> {:ok, rank}
      :error -> :error
    end
  end

  def dump_to_native(_other, _constraints), do: :error
end
