defmodule Samen.Type.Emails do
  @moduledoc """
  Composite PII type `%Samen.Type.Emails{}` — a labelled list of email addresses
  (doc §core person table; plan D1).

  ## Twenty CRM is the SPEC, not a dependency

  Twenty CRM models a contact's emails as a primary address plus a list of
  additional addresses. Samen re-implements the SPEC as a `label + address` list:

      pii_attribute :emails, Samen.Type.Emails, vault: :pii_email

  The value is:

      %Samen.Type.Emails{
        entries: [
          %{label: "work", address: "grace@example.com"},
          %{label: "home", address: "grace@home.example"}
        ]
      }

  ## Composite routing / classification

  As a composite type it routes by vault name (abbrev prefix, no `pii_` column
  prefix) and is registered PII in `Samen.Pii.Classification`. Declaring it
  outside a `pii do` block is a classification error, never a plain column.
  """
  use Ash.Type

  @enforce_keys []
  defstruct entries: []

  @type entry :: %{label: String.t() | nil, address: String.t()}
  @type t :: %__MODULE__{entries: [entry()]}

  @impl true
  def storage_type(_constraints), do: :map

  @doc "Self-classification for `Samen.Pii.Classification`: emails are PII."
  def samen_pii_class, do: :pii

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%__MODULE__{} = v, _constraints), do: {:ok, v}

  def cast_input(list, _constraints) when is_list(list) do
    with {:ok, entries} <- cast_entries(list) do
      {:ok, %__MODULE__{entries: entries}}
    end
  end

  def cast_input(%{} = map, constraints) do
    case fetch(map, :entries) do
      nil -> :error
      list -> cast_input(list, constraints)
    end
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(%{} = map, constraints) do
    list = fetch(map, :entries) || []
    cast_input(list, constraints)
  end

  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%__MODULE__{entries: entries}, _constraints) do
    {:ok,
     %{
       "entries" =>
         Enum.map(entries, fn e ->
           %{"label" => fetch(e, :label), "address" => fetch(e, :address)}
         end)
     }}
  end

  def dump_to_native(_other, _constraints), do: :error

  defp cast_entries(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case cast_entry(item) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp cast_entry(%{} = item) do
    case fetch(item, :address) do
      addr when is_binary(addr) -> {:ok, %{label: fetch(item, :label), address: addr}}
      _ -> :error
    end
  end

  defp cast_entry(_), do: :error

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
