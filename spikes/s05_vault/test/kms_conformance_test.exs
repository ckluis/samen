defmodule Samen.KmsConformanceTest do
  @moduledoc """
  Contract tests: both dev adapters (InMemory, FileBacked) implement the SAME
  `Samen.Kms` behaviour semantics (ADR-001 §8.1). The production adapter
  (AwsKmsDynamo, T1.4) must pass this same suite so the spike guarantee carries
  to prod.
  """
  use ExUnit.Case, async: false

  @adapters [Samen.Kms.FileBacked, Samen.Kms.InMemory]

  setup do
    # The supervised InMemory agent is fine as-is: every test uses a UNIQUE
    # subject id (`conf-<unique_integer>`), so no cross-test state bleeds. We
    # only ensure it is running.
    unless Process.whereis(Samen.Kms.InMemory), do: Samen.Kms.InMemory.start_link()

    Samen.Kms.FileBacked.simulate_outage(false)
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
        assert {:ok, %{state: :shredded, destroyed_at: dt, attestation_id: aid}} = @adapter.shred(s)
        assert dt != nil
        assert is_binary(aid)
        assert {:error, :shredded} = @adapter.unwrap(s)
      end

      test "attest after shred stays :shredded (positive tombstone, not absence)" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        {:ok, _} = @adapter.shred(s)
        assert {:ok, %{state: :shredded}} = @adapter.attest(s)
      end

      test "attest of unknown subject is :absent" do
        assert {:ok, %{state: :absent}} = @adapter.attest("never-#{System.unique_integer()}")
      end

      test "backups_disabled? is true for the dev external store" do
        assert @adapter.backups_disabled?() == true
      end

      test "pseudonym is stable pre-shred and denied post-shred (RQ5)" do
        s = subj()
        {:ok, _} = @adapter.generate_subject_key(s)
        assert {:ok, p1} = @adapter.pseudonym(s, s)
        assert {:ok, p2} = @adapter.pseudonym(s, s)
        assert p1 == p2
        {:ok, _} = @adapter.shred(s)
        assert {:error, :shredded} = @adapter.pseudonym(s, s)
      end
    end
  end

  defp subj, do: "conf-#{System.unique_integer([:positive])}"
end
