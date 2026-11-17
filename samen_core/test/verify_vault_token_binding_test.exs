defmodule SamenCore.VerifyVaultTokenBindingTest do
  @moduledoc """
  `mix samen.verify.vault_token_binding` / `Samen.Vault.BindingScan` (T-V of the 2026-11-13
  token-binding design): each finding class is detected, a clean database passes, the output
  carries no token and no value, and an empty discovery fails closed.

  Two layers (as `verify_vault_declared_parity_test.exs`): the unit layer plants a defect with raw
  SQL inside the sandbox and calls `check/3` directly; the exit-code layer COMMITS (`auto!/1`) and
  runs the real mix task in a child OS process, the only way to observe `:erlang.halt(1)`.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.VaultTokenBinding, as: Task
  alias Samen.Vault
  alias Samen.Vault.BindingScan
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.TestRepo, as: Repo

  @project_dir Path.expand("../", __DIR__)

  setup context do
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    if context[:exit_code] do
      Samen.TestSandbox.auto!(Repo)
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    :ok
  end

  defp resources do
    :samen_core
    |> Application.get_env(:ash_domains, [])
    |> Samen.Catalog.resource_modules()
  end

  defp create_patient(mrn \\ "MRN-#{System.unique_integer([:positive])}") do
    Patient
    |> Ash.Changeset.for_create(:create, %{
      org_id: Ash.UUID.generate(),
      full_name: %{first: "Grace", last: "Hopper"},
      mrn: mrn,
      dob: ~D[1906-12-09]
    })
    |> Ash.create!()
  end

  defp raw_cell(patient, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(patient.id)])

    value
  end

  defp plant(patient, column, value) do
    Repo.query!("UPDATE pat_patient SET #{column} = $1 WHERE pat_id = $2", [value, Ecto.UUID.dump!(patient.id)])
  end

  defp lines(opts \\ []), do: Task.check(Repo, resources(), opts)

  defp mentions?(lines, class, patient, field) do
    Enum.any?(lines, &(&1 =~ "#{class}:" and &1 =~ ".#{field} record #{patient.id}"))
  end

  describe "green path" do
    test "a database whose every token belongs to its record, vault and field is clean" do
      create_patient()
      create_patient()

      assert lines() == []
      {[], stats} = BindingScan.scan(Repo, resources())
      assert stats.columns > 0
      assert stats.cells >= 6, "the scan must have examined the planted records' cells, got #{inspect(stats)}"
    end

    test "NULL cells are not examined (an unset optional field is not a finding)" do
      patient = create_patient()
      plant(patient, "pii_pat_mrn", nil)
      assert lines() == []
    end
  end

  describe "RED PATH: each class is detected (positive control: the untouched record is never named)" do
    test "foreign_subject (and shared_token for both holders): B's cell carries A's token" do
      a = create_patient()
      b = create_patient()
      plant(b, "pii_pat_mrn", raw_cell(a, "pii_pat_mrn"))

      found = lines()

      assert mentions?(found, :foreign_subject, b, :mrn)
      refute mentions?(found, :foreign_subject, a, :mrn)
      assert mentions?(found, :shared_token, a, :mrn)
      assert mentions?(found, :shared_token, b, :mrn)
      # the rest of both records is untouched and clean
      refute Enum.any?(found, &(&1 =~ ".dob record") or &1 =~ ".full_name record"), inspect(found)
    end

    test "foreign_subject across a shared-token-free plant: a token of a subject that holds no record here" do
      b = create_patient()
      {:ok, stray} = Vault.store_field(Ash.UUID.generate(), :pii_mrn, :mrn, "someone-else", Repo)
      plant(b, "pii_pat_mrn", stray)

      found = lines()
      assert mentions?(found, :foreign_subject, b, :mrn)
      refute Enum.any?(found, &(&1 =~ "shared_token:")), inspect(found)
    end

    test "field_mismatch: this record's own subject, but the row is for another field" do
      a = create_patient()
      {:ok, renamed} = Vault.store_field(a.id, :pii_mrn, :renamed_field, "x", Repo)
      plant(a, "pii_pat_mrn", renamed)

      found = lines()
      assert mentions?(found, :field_mismatch, a, :mrn)
      refute mentions?(found, :foreign_subject, a, :mrn)
    end

    test "field_mismatch: this record's own subject, but the row is in another vault" do
      a = create_patient()
      {:ok, other_vault} = Vault.store_field(a.id, :pii_dob, :mrn, "x", Repo)
      plant(a, "pii_pat_mrn", other_vault)

      assert mentions?(lines(), :field_mismatch, a, :mrn)
    end

    test "dangling_token: token-shaped, no vault row" do
      a = create_patient()
      plant(a, "pii_pat_mrn", Vault.generate_token())

      found = lines()
      assert mentions?(found, :dangling_token, a, :mrn)
    end

    test "non_token_value: plaintext at rest, including a vt_-prefixed one" do
      a = create_patient()
      b = create_patient()
      plant(a, "pii_pat_mrn", "vt_ please help")
      plant(b, "pii_pat_mrn", "MRN-PLAINTEXT")

      found = lines()
      assert mentions?(found, :non_token_value, a, :mrn)
      assert mentions?(found, :non_token_value, b, :mrn)
    end

    test "a cell is classified once by the first class that applies (non-token is not also dangling)" do
      a = create_patient()
      plant(a, "pii_pat_mrn", "vt_short")

      found = Enum.filter(lines(), &(&1 =~ ".mrn record #{a.id}"))
      assert found == ["non_token_value: #{inspect(Patient)}.mrn record #{a.id}"]
    end
  end

  describe "output discipline" do
    test "no finding line contains a token or a value" do
      a = create_patient()
      b = create_patient()
      foreign = raw_cell(a, "pii_pat_mrn")
      plant(b, "pii_pat_mrn", foreign)
      plant(a, "pii_pat_dob", "vt_leaky plaintext 4111")
      dangling = Vault.generate_token()
      plant(a, "pat_full_name", dangling)

      found = lines()
      assert found != []
      blob = Enum.join(found, "\n")

      for secret <- [foreign, dangling, "leaky plaintext", "4111", "vt_"] do
        refute blob =~ secret, "a finding leaked #{inspect(secret)}"
      end

      for line <- found, do: assert(line =~ ~r/^[a-z_]+: [A-Za-z.]+\.[a-z_]+ record [0-9a-f-]{36}$/)
    end
  end

  describe "keyset paging" do
    test "page_size 1 finds exactly what one big page finds" do
      for _ <- 1..4, do: create_patient()
      victim = create_patient()
      plant(victim, "pii_pat_mrn", Vault.generate_token())

      {big, big_stats} = BindingScan.scan(Repo, resources(), page_size: 1000)
      {small, small_stats} = BindingScan.scan(Repo, resources(), page_size: 1)

      assert small == big
      assert small_stats == big_stats
      assert Enum.any?(small, &(&1.class == :dangling_token and &1.record_id == victim.id))
    end
  end

  describe "fail-closed" do
    test "check/3 raises when no vault-routed column was examined" do
      assert_raise RuntimeError, ~r/vacuous/, fn -> Task.check(Repo, []) end
    end
  end

  describe "the mix task's exit code" do
    @tag :exit_code
    test "exits 0 on a clean database and 1 on a planted foreign token, naming class and record, never the token" do
      a = create_patient()
      b = create_patient()

      on_exit(fn ->
        for p <- [a, b] do
          Repo.query!("DELETE FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])
          Repo.query!("DELETE FROM pii_vault WHERE subject_id = $1", [p.id])
        end
      end)

      {clean_out, clean_code} = run_task()
      assert clean_code == 0, clean_out
      assert clean_out =~ "OK — no violations found"

      foreign = raw_cell(a, "pii_pat_mrn")
      plant(b, "pii_pat_mrn", foreign)

      {out, code} = run_task()
      assert code == 1, out
      assert out =~ "foreign_subject: #{inspect(Patient)}.mrn record #{b.id}"
      refute out =~ foreign
    end

    @tag :exit_code
    test "exits 1 with the fail-closed diagnostic when ash_domains is empty" do
      {out, code} = run_task([{"SAMEN_EMPTY_ASH_DOMAINS", "1"}])
      assert code == 1, out
      assert out =~ "ZERO resources"
    end
  end

  defp run_task(extra_env \\ []) do
    System.cmd("mix", ["samen.verify.vault_token_binding"],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"} | extra_env],
      stderr_to_stdout: true
    )
  end
end
