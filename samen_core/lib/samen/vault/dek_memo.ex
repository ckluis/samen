defmodule Samen.Vault.DekMemo do
  @moduledoc """
  The unwrapped DEKs of ONE resolve call (ADR-001 §6 addendum, 2026-11-14): `unwrap/1` per
  SUBJECT instead of per vaulted VALUE.

  A `DekMemo` is a plain value built by `Samen.Vault.unwrap_subjects/1`, carried in the
  resolve call's `opts` and handed to `Samen.Vault.reveal/3` as `deks:`. It is NOT a cache:
  no process dictionary, no ETS, no `persistent_term`, no TTL — when the call returns the
  value is unreachable, so the NEXT call unwraps again and a subject shredded in between
  yields nothing (deny-on-read, crypto-shred stays immediate).

  Entries are keyed `{adapter, subject_id}` — everything `Samen.Kms.unwrap/1` depends on
  (the wrapped DEK, its org and master-key version live behind the adapter, addressed by the
  subject id alone). A failed unwrap is held as its `{:error, reason}` — never as success,
  never as a key — so it denies that subject's values only.

  It holds raw key bytes, so `Inspect` is redacted and `Samen.Vault` is the only reader.
  """

  @enforce_keys [:entries]
  defstruct entries: %{}

  @opaque t :: %__MODULE__{}

  @doc false
  @spec new(%{{module(), String.t()} => {:ok, binary()} | {:error, term()}}) :: t()
  def new(entries) when is_map(entries), do: %__MODULE__{entries: entries}

  @doc false
  @spec fetch(t(), module(), String.t()) :: {:ok, {:ok, binary()} | {:error, term()}} | :error
  def fetch(%__MODULE__{entries: entries}, adapter, subject_id),
    do: Map.fetch(entries, {adapter, subject_id})

  defimpl Inspect do
    def inspect(%Samen.Vault.DekMemo{entries: entries}, _opts),
      do: "#Samen.Vault.DekMemo<**redacted** subjects: #{map_size(entries)}>"
  end
end
