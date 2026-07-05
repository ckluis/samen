defmodule Samen.ShredKeyMaterialTest do
  @moduledoc """
  Gate-0 vault-stack fix (P2, shred defence-in-depth): post-shred deny must depend
  on ACTUAL key-material destruction, not tombstone presence alone.

  The load-bearing red path: a "shred" that writes a positive tombstone but LEAVES
  the wrapped DEK behind is NOT a real erasure (the key is still recoverable), and
  `Samen.Erasure.erased?/1` must return `false` for it — even though the
  attestation says `:shredded`. We prove this with a deliberately-broken adapter
  whose `shred/1` tombstones without destroying the key.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.Erasure
  alias Samen.Vault

  @repo SamenCore.TestRepo

  # A saboteur adapter: shred writes a POSITIVE tombstone (state :shredded) but
  # LEAVES the key material present. This models the failure the P2 fix defends
  # against — a tombstone-only shred with the DEK still recoverable.
  defmodule LeakyShredAdapter do
    @behaviour Samen.Kms

    alias Samen.Kms.InMemory

    @impl true
    def generate_subject_key(s), do: InMemory.generate_subject_key(s)

    @impl true
    def unwrap(s), do: InMemory.unwrap(s)

    @impl true
    def attest(_subject_id) do
      # Lies: claims a positive tombstone even though the key was never destroyed.
      {:ok,
       %{
         subject_id: "x",
         state: :shredded,
         destroyed_at: DateTime.utc_now(),
         attestation_id: "leaky-att",
         km_version: nil,
         checked_at: DateTime.utc_now()
       }}
    end

    @impl true
    def shred(_subject_id) do
      # Writes a positive tombstone but DOES NOT destroy the key material.
      {:ok,
       %{
         subject_id: "x",
         state: :shredded,
         destroyed_at: DateTime.utc_now(),
         attestation_id: "leaky-att",
         km_version: nil,
         checked_at: DateTime.utc_now()
       }}
    end

    @impl true
    # The tell: the key material is STILL PRESENT. This is what the P2 check reads.
    def key_material_present?(_subject_id), do: true

    @impl true
    def backups_disabled?, do: true

    @impl true
    def pseudonym(s, t), do: InMemory.pseudonym(s, t)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)
    :ok
  end

  defp subj, do: "shred-km-#{System.unique_integer([:positive])}"

  test "RED PATH: a tombstone-written-but-DEK-left shred does NOT count as erased" do
    Application.put_env(:samen_core, :kms_adapter, LeakyShredAdapter)
    s = subj()

    {:ok, _} = Vault.store_field(s, :pii_email, :emails, "leak@example.com", @repo)

    # The saboteur "shreds": writes a positive tombstone, but leaves the DEK. Run
    # the FULL orchestration so the DB-tier clause of erased?/1 (no active vault
    # rows) is SATISFIED — isolating the key-material clause as the only thing that
    # can (and must) make erased? false. Without the P2 check, this row would be
    # wrongly reported as erased.
    {:ok, %{attestation: att}} = Erasure.shred(s, repo: @repo)
    assert att.state == :shredded, "the tombstone LOOKS positive (that's the trap)"

    # Prove the DB-tier clause passes on its own (all vault rows sealed) — so the
    # ONLY thing that can fail erased? here is the key-material presence check.
    active =
      @repo.aggregate(
        from(v in Samen.Vault.VaultRow, where: v.subject_id == ^s and v.state == "active"),
        :count
      )

    assert active == 0, "vault rows are sealed — DB-tier clause is satisfied"

    # DEFENCE IN DEPTH: despite a positive tombstone AND zero active vault rows,
    # erased?/1 must return FALSE because the key material survives (recoverable).
    refute Erasure.erased?(s, repo: @repo),
           "erased? must be FALSE when key material survives, even with a positive tombstone and sealed rows"
  end

  test "a REAL shred (key material actually destroyed) DOES count as erased" do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    s = subj()

    {:ok, _} = Vault.store_field(s, :pii_email, :emails, "real@example.com", @repo)
    {:ok, att} = Vault.shred(s)
    assert att.state == :shredded

    # Real shred: the DEK is actually gone.
    assert Samen.Kms.FileBacked.key_material_present?(s) == false

    # Seal the vault rows (the DB-tier witness) via the full erasure orchestration
    # so erased?/1's "no active vault rows" clause is satisfied too.
    {:ok, _} = Erasure.shred(s, repo: @repo)
    assert Erasure.erased?(s, repo: @repo)
    assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(s, @repo)
  end
end
