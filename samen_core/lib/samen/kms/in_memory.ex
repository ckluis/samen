defmodule Samen.Kms.InMemory do
  @moduledoc """
  In-memory `Samen.Kms` adapter (ADR-001 §8.1).

  An `Agent`-backed map `subject_id => {wrapped_dek, tombstone}`. `shred/1`
  drops the wrapped DEK and records a tombstone with `state: :shredded`.
  Fastest; used by unit/property suites. Deliberately loses state on process
  death — models "no persistence in the app's own durable surface."

  The master key is a per-process random dev key: it is NOT persisted, so even
  the master cannot resurrect a DEK after the Agent dies. Shred is modeled by
  removing the wrapped DEK from the store; the tombstone carries no key
  material.

  ## T1.4 note: no TTL cache (ADR-001 §6 seam)

  This adapter makes no attempt to cache unwrapped DEKs. Every `unwrap/1` call
  re-derives the DEK from the wrapped bytes in the store. The ADR-001 §6 seam
  for an optional TTL cache is documented in `Samen.Kms`; add it there if needed.
  """

  @behaviour Samen.Kms

  alias Samen.Kms.Crypto

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{master: Crypto.generate_dek(), store: %{}} end, name: name)
  end

  @impl true
  def generate_subject_key(subject_id) do
    ensure_started()

    Agent.get_and_update(__MODULE__, fn state ->
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap(state.master, dek)

      row = %{
        wrapped_dek: wrapped,
        state: :active,
        created_at: DateTime.utc_now(),
        destroyed_at: nil,
        attestation_id: nil,
        km_version: "dev-mem-v1"
      }

      {{:ok, wrapped}, put_in(state.store[subject_id], row)}
    end)
  end

  @impl true
  def unwrap(subject_id) do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      case Map.get(state.store, subject_id) do
        %{state: :active, wrapped_dek: wrapped} -> Crypto.unwrap(state.master, wrapped)
        %{state: :shredded} -> {:error, :shredded}
        nil -> {:error, :absent}
      end
    end)
  end

  @impl true
  def shred(subject_id) do
    ensure_started()

    Agent.get_and_update(__MODULE__, fn state ->
      now = DateTime.utc_now()
      attestation_id = "mem-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      case Map.get(state.store, subject_id) do
        nil ->
          {{:error, :absent}, state}

        row ->
          # Remove the wrapped DEK; keep a positive tombstone (ADR-001 §3).
          # DEFENCE IN DEPTH (Gate-0 P2): the tombstone carries NO key material —
          # `:SHREDDED` is a sentinel, never wrapped bytes. key_material_present?/1
          # reads this to confirm actual destruction (not tombstone-presence alone).
          tomb = %{
            row
            | wrapped_dek: :SHREDDED,
              state: :shredded,
              destroyed_at: now,
              attestation_id: attestation_id,
              km_version: nil
          }

          attestation = %{
            subject_id: subject_id,
            state: :shredded,
            destroyed_at: now,
            attestation_id: attestation_id,
            km_version: nil,
            checked_at: now
          }

          {{:ok, attestation}, put_in(state.store[subject_id], tomb)}
      end
    end)
  end

  @impl true
  def attest(subject_id) do
    ensure_started()
    now = DateTime.utc_now()

    Agent.get(__MODULE__, fn state ->
      att =
        case Map.get(state.store, subject_id) do
          nil ->
            %{state: :absent, destroyed_at: nil, attestation_id: nil, km_version: nil}

          row ->
            %{
              state: row.state,
              destroyed_at: row.destroyed_at,
              attestation_id: row.attestation_id,
              km_version: row.km_version
            }
        end

      {:ok, Map.merge(att, %{subject_id: subject_id, checked_at: now})}
    end)
  end

  @impl true
  def backups_disabled?, do: true

  @impl true
  def key_material_present?(subject_id) do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      case Map.get(state.store, subject_id) do
        %{wrapped_dek: :SHREDDED} -> false
        %{wrapped_dek: wrapped} when is_binary(wrapped) -> true
        _ -> false
      end
    end)
  end

  @impl true
  def pseudonym(subject_id, target_subject_id) do
    case unwrap(subject_id) do
      {:ok, dek} -> {:ok, Crypto.pseudonym(dek, target_subject_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_active_subjects do
    ensure_started()

    subjects =
      Agent.get(__MODULE__, fn state ->
        state.store
        |> Enum.filter(fn {_id, row} -> row.state == :active end)
        |> Enum.map(fn {id, _row} -> id end)
      end)

    {:ok, subjects}
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end
