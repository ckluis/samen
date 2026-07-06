defmodule Samen.Kms.FileBacked do
  @moduledoc """
  File-backed `Samen.Kms` adapter (ADR-001 §8.1) — the external-store simulator.

  Wrapped DEKs and the dev master key are written to a **key directory that
  lives outside the Postgres data dir and outside any repo/backup path**. This
  is the adapter the T1.4 red-path tests run against, because it can simulate
  the load-bearing PITR claim:

    - the vault/Postgres snapshot (`pg_dump`) is taken WITHOUT the key
      directory, so
    - a "restore" of the dump alone provably lacks the keys, so
    - decrypt of the restored ciphertext is impossible.

  ## Layout of the key store (external to Postgres)

      <key_dir>/master.key                 32-byte dev master (the KMS CMK stand-in)
      <key_dir>/subjects/<subject_id>.dek  wrapped DEK (KMS.Encrypt output)
      <key_dir>/subjects/<subject_id>.tombstone  positive tombstone (JSON) after shred

  `shred/1` deletes the `.dek` file and writes a `.tombstone` JSON
  (`state`, `destroyed_at`, `attestation_id`). Deletion is final — there is no
  time-travel over this directory (it is never in the Postgres dump).

  ## Fail-closed on store outage (RQ4)

  If the key directory is made unreachable (path swapped to a nonexistent
  location via `simulate_outage/1`), `unwrap/1` returns `{:error, :unavailable}`
  — it never falls back to any cached or local plaintext key.

  ## T1.4 note: no TTL cache (ADR-001 §6 seam)

  This adapter makes no attempt to cache unwrapped DEKs. Every `unwrap/1` is a
  live file read. The ADR-001 §6 seam for an optional TTL cache is documented in
  `Samen.Kms`; if added, it must evict on shred and deny on outage.
  """

  @behaviour Samen.Kms

  alias Samen.Kms.Crypto

  @outage_key {__MODULE__, :outage}

  @doc """
  The absolute key directory. External to Postgres by construction: defaults to
  a per-run tmp dir under the system temp root, configurable via
  `:samen_core, :kms_key_dir`. NEVER under the Postgres data dir or the repo.
  """
  @spec key_dir() :: String.t()
  def key_dir do
    Application.get_env(:samen_core, :kms_key_dir) ||
      Path.join(System.tmp_dir!(), "samen_core_keystore")
  end

  @doc "Initialize the key store (idempotent). Generates the dev master if absent."
  @spec init!() :: :ok
  def init! do
    dir = key_dir()
    File.mkdir_p!(Path.join(dir, "subjects"))

    master_path = Path.join(dir, "master.key")

    unless File.exists?(master_path) do
      File.write!(master_path, Crypto.generate_dek(), [:binary])
      File.chmod!(master_path, 0o600)
    end

    :ok
  end

  @doc """
  Simulate a key-store/KMS outage (RQ4). When `true`, all store reads resolve
  against a nonexistent path so `unwrap/1` fails closed with `:unavailable`.

  Used by red-path tests only. Always reset to `false` in test teardown.
  """
  @spec simulate_outage(boolean()) :: :ok
  def simulate_outage(bool) when is_boolean(bool) do
    :persistent_term.put(@outage_key, bool)
    :ok
  end

  defp outage?, do: :persistent_term.get(@outage_key, false)

  defp effective_dir do
    if outage?() do
      # Point at a path that cannot exist — models the store being unreachable.
      Path.join(
        System.tmp_dir!(),
        "samen_core_keystore__UNREACHABLE__#{:erlang.unique_integer()}"
      )
    else
      key_dir()
    end
  end

  defp master do
    path = Path.join(effective_dir(), "master.key")

    case File.read(path) do
      {:ok, <<k::binary-size(32)>>} -> {:ok, k}
      {:ok, _bad} -> {:error, :unavailable}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp dek_path(subject_id), do: Path.join([key_dir(), "subjects", "#{subject_id}.dek"])
  defp tomb_path(subject_id), do: Path.join([key_dir(), "subjects", "#{subject_id}.tombstone"])

  defp eff_dek_path(subject_id),
    do: Path.join([effective_dir(), "subjects", "#{subject_id}.dek"])

  @impl true
  def generate_subject_key(subject_id) do
    init!()

    with {:ok, master} <- master() do
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap(master, dek)
      File.write!(dek_path(subject_id), wrapped, [:binary])
      File.chmod!(dek_path(subject_id), 0o600)
      {:ok, wrapped}
    end
  end

  @impl true
  def unwrap(subject_id) do
    cond do
      outage?() ->
        {:error, :unavailable}

      File.exists?(tomb_path(subject_id)) ->
        {:error, :shredded}

      true ->
        with {:ok, master} <- master(),
             {:ok, wrapped} <- read_dek(subject_id) do
          Crypto.unwrap(master, wrapped)
        end
    end
  end

  defp read_dek(subject_id) do
    case File.read(eff_dek_path(subject_id)) do
      {:ok, wrapped} -> {:ok, wrapped}
      {:error, :enoent} -> if outage?(), do: {:error, :unavailable}, else: {:error, :absent}
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def shred(subject_id) do
    init!()
    now = DateTime.utc_now()
    attestation_id = "file-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    dek = dek_path(subject_id)
    tomb = tomb_path(subject_id)

    cond do
      # Already shredded — idempotent, return existing tombstone attestation.
      File.exists?(tomb) ->
        {:ok, Map.put(read_tombstone!(subject_id), :checked_at, now)}

      not File.exists?(dek) ->
        {:error, :absent}

      true ->
        # 1. Destroy the ONLY wrapped copy of the DEK. Final — no PITR here.
        :ok = File.rm(dek)

        # DEFENCE IN DEPTH (Gate-0 P2): the tombstone is trustworthy ONLY if the
        # key material is actually gone. Verify the wrapped DEK no longer exists
        # BEFORE writing the tombstone — a tombstone written over a surviving DEK
        # would be a false attestation (the key is still recoverable). Fail closed.
        if File.exists?(dek) do
          {:error, :key_material_not_destroyed}
        else
          # 2. Write a positive tombstone (system-of-record for the oracle).
          attestation = %{
            subject_id: subject_id,
            state: :shredded,
            destroyed_at: DateTime.to_iso8601(now),
            attestation_id: attestation_id,
            km_version: nil
          }

          File.write!(tomb, Jason.encode!(attestation))
          {:ok, to_attestation(attestation, now)}
        end
    end
  end

  @impl true
  def key_material_present?(subject_id) do
    File.exists?(dek_path(subject_id))
  end

  @impl true
  def attest(subject_id) do
    now = DateTime.utc_now()

    att =
      cond do
        File.exists?(tomb_path(subject_id)) ->
          read_tombstone!(subject_id)
          |> Map.take([:subject_id, :state, :destroyed_at, :attestation_id, :km_version])

        File.exists?(dek_path(subject_id)) ->
          %{
            subject_id: subject_id,
            state: :active,
            destroyed_at: nil,
            attestation_id: nil,
            km_version: "dev-file-v1"
          }

        true ->
          %{
            subject_id: subject_id,
            state: :absent,
            destroyed_at: nil,
            attestation_id: nil,
            km_version: nil
          }
      end

    {:ok, Map.put(att, :checked_at, now)}
  end

  @impl true
  def backups_disabled? do
    # The key store is a plain directory outside Postgres. There is no
    # continuous-backup / PITR facility over it by construction. Production
    # (AwsKmsDynamo) implements this via DescribeContinuousBackups == DISABLED.
    true
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
    subjects_dir = Path.join(key_dir(), "subjects")

    case File.ls(subjects_dir) do
      {:ok, entries} ->
        active =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".dek"))
          |> Enum.map(&String.replace_suffix(&1, ".dek", ""))
          # A subject with a tombstone is shredded even if a .dek somehow lingers;
          # key on the ADAPTER's own live/shredded state, not just file presence.
          |> Enum.reject(fn id -> File.exists?(tomb_path(id)) end)

        {:ok, active}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_tombstone!(subject_id) do
    map =
      tomb_path(subject_id)
      |> File.read!()
      |> Jason.decode!(keys: :atoms)

    # JSON serializes :shredded as "shredded" and the DateTime as an ISO8601
    # string; normalize back to the behaviour's attestation shape.
    %{
      map
      | state: normalize_state(map.state),
        destroyed_at: normalize_dt(map.destroyed_at)
    }
  end

  defp normalize_state("shredded"), do: :shredded
  defp normalize_state("active"), do: :active
  defp normalize_state("absent"), do: :absent
  defp normalize_state(s) when is_atom(s), do: s

  defp normalize_dt(nil), do: nil

  defp normalize_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> iso
    end
  end

  defp normalize_dt(%DateTime{} = dt), do: dt

  defp to_attestation(map, now) do
    %{
      subject_id: map.subject_id,
      state: :shredded,
      destroyed_at: now,
      attestation_id: map.attestation_id,
      km_version: nil,
      checked_at: now
    }
  end
end
