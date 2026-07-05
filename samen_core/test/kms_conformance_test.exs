defmodule Samen.KmsConformanceTest do
  @moduledoc """
  Contract tests: all three KMS adapters (InMemory, FileBacked, AwsKmsDynamo)
  implement the SAME `Samen.Kms` behaviour semantics (ADR-001 §8.1; T1.4).

  AwsKmsDynamo is tested in disabled mode (aws_kms_dynamo_enabled: false) where
  it delegates to InMemory — this verifies the skeleton compiles and passes the
  conformance suite shape without a live AWS account.
  """
  use ExUnit.Case, async: false

  @adapters [Samen.Kms.FileBacked, Samen.Kms.InMemory, Samen.Kms.AwsKmsDynamo]

  setup do
    # InMemory agent is supervised — ensure it is running.
    unless Process.whereis(Samen.Kms.InMemory), do: Samen.Kms.InMemory.start_link()
    # Reset FileBacked outage flag.
    Samen.Kms.FileBacked.simulate_outage(false)
    # AwsKmsDynamo delegates to InMemory in disabled mode; ensure InMemory is running.
    :ok
  end

  for adapter <- @adapters do
    @adapter adapter

    describe "#{inspect(adapter)}" do
      test "implements the Samen.Kms behaviour" do
        behaviours =
          @adapter.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Samen.Kms in behaviours
      end

      test "generate -> unwrap round trip yields a 32-byte DEK" do
        s = subj()
        assert {:ok, _wrapped} = @adapter.generate_subject_key(s)
        assert {:ok, dek} = @adapter.unwrap(s)
        assert byte_size(dek) == 32
      end

      test "attest of active subject reports :active" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        assert {:ok, %{state: :active}} = @adapter.attest(s)
      end

      test "shred yields a positive attestation and denies unwrap" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)

        assert {:ok, %{state: :shredded, destroyed_at: dt, attestation_id: aid}} =
                 @adapter.shred(s)

        assert dt != nil
        assert is_binary(aid)
        assert {:error, :shredded} = @adapter.unwrap(s)
      end

      test "attest after shred stays :shredded (positive tombstone, not absence) — RED PATH 3" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        {:ok, _} = @adapter.shred(s)
        # ADR-001 red path 3: absent != shredded; must be a POSITIVE tombstone.
        assert {:ok, %{state: :shredded}} = @adapter.attest(s)
      end

      test "key_material_present? tracks ACTUAL DEK destruction, not the tombstone — P2 shred defence-in-depth" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        # Before shred, the wrapped DEK exists.
        assert @adapter.key_material_present?(s) == true

        {:ok, _} = @adapter.shred(s)

        # RED PATH (Gate-0 P2): post-shred, the KEY MATERIAL must actually be gone,
        # independent of the tombstone. If shred only wrote a tombstone but left the
        # DEK, this would be true — and the key would still be recoverable. It MUST
        # be false: deny post-shred depends on real key destruction.
        assert @adapter.key_material_present?(s) == false
      end

      test "key_material_present? is false for a never-seen subject" do
        assert @adapter.key_material_present?("never-#{System.unique_integer()}") == false
      end

      test "attest of unknown subject is :absent (not :shredded)" do
        # :absent is FAIL for a post-shred oracle assertion (ADR-001 §5).
        # This test verifies the adapter correctly distinguishes :absent from :shredded.
        assert {:ok, %{state: :absent}} = @adapter.attest("never-#{System.unique_integer()}")
      end

      test "backups_disabled? is true for the dev/stub external store" do
        assert @adapter.backups_disabled?() == true
      end

      test "pseudonym is stable pre-shred and denied post-shred — RED PATH 4 (RQ5)" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        assert {:ok, p1} = @adapter.pseudonym(s, s)
        assert {:ok, p2} = @adapter.pseudonym(s, s)
        # Stable: same input always produces same pseudonym.
        assert p1 == p2
        assert byte_size(p1) == 64

        {:ok, _} = @adapter.shred(s)
        # RED PATH 4: after shred, pseudonym key is unreconstructable (RQ5).
        assert {:error, :shredded} = @adapter.pseudonym(s, s)
      end
    end
  end

  defp subj, do: "conf-#{System.unique_integer([:positive])}"
end
