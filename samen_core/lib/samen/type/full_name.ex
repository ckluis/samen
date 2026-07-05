defmodule Samen.Type.FullName do
  @moduledoc """
  Composite PII type `%Samen.Type.FullName{}` — the classification unit for a
  person's name (doc §core person table; plan D1).

  ## Twenty CRM is the SPEC, not a dependency

  Twenty CRM models a full name as a `{first, last}` pair. Samen re-implements
  that *shape* as a first-class `Ash.Type` (memory: "Twenty = a SPEC, not a
  dependency") so a name is a single, vault-routable value rather than two loose
  string columns the PII classifier would have to catch one at a time.

      pii_attribute :full_name, Samen.Type.FullName, vault: :pii_name

  The value is `%Samen.Type.FullName{first: "Grace", last: "Hopper"}`.

  ## Why composite = the classification unit

  Routing a *composite* field to a vault carries the resource abbrev but **no**
  `pii_` column prefix (vision doc §core "PII routing note": composite fields
  route by vault name). The whole struct is one vault-routed value; downstream
  verifiers key on the `pii do` / vault **declaration**, never on a `pii_` name.

  ## Classification

  This type is registered PII in `Samen.Pii.Classification` — it is a composite
  PII shape by construction, so declaring it OUTSIDE a `pii do` block is a
  classification error the `pii_classify` verifier (C4, T1.8c) is built to catch,
  not a silently-plain column.
  """
  use Ash.Type

  @enforce_keys []
  defstruct [:first, :last]

  @type t :: %__MODULE__{first: String.t() | nil, last: String.t() | nil}

  @impl true
  def storage_type(_constraints), do: :map

  @doc "Self-classification for `Samen.Pii.Classification`: a name is PII."
  def samen_pii_class, do: :pii

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%__MODULE__{} = v, _constraints), do: {:ok, v}

  def cast_input(%{} = map, _constraints) do
    {:ok,
     %__MODULE__{
       first: fetch(map, :first),
       last: fetch(map, :last)
     }}
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(%{} = map, _constraints) do
    {:ok, %__MODULE__{first: fetch(map, :first), last: fetch(map, :last)}}
  end

  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%__MODULE__{first: first, last: last}, _constraints) do
    {:ok, %{"first" => first, "last" => last}}
  end

  def dump_to_native(_other, _constraints), do: :error

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
