defmodule Samen.PiiResolutionTokenBindingTest do
  @moduledoc """
  Token binding on the READ side (evaluation 2026-11-13, T-R1/T-R3): a vault token held by a record
  reveals ONLY as that record's value for that field. A token planted from another subject (legacy or
  tampered data: the write side now refuses it, `Samen.Vault.Change`) renders masked/absent on EVERY
  plane, across orgs too, and is reported once per call with no token in the metadata.

  Per plane (`Samen.MaskingCase`): tenant, operator with a grant, operator without, impersonation, AI
  egress. Each red path pairs with a positive control: the record's OWN token on the same page is clear
  wherever the plane allows. The DEK leg (the foreign subject is never unwrapped) is in
  `vault_dek_reuse_test.exs`.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  # MUTATION_OWNS: samen_core/lib/samen/api/pii_resolution.ex samen_core/lib/samen/vault.ex

  alias Samen.Api.PiiResolution
  alias Samen.Masked
  alias Samen.Vault
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.Support.CrmScopeFixture.Person

  @repo SamenCore.TestRepo

  defmodule AllowAll do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, fn _ -> true end)
    def granted?(_), do: true
  end

  defmodule DenyAll do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, fn _ -> false end)
    def granted?(_), do: false
  end

  setup do
    Samen.TestSandbox.shared!(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  # --- fixtures ------------------------------------------------------------------------------------------

  # A Person-shaped record whose three PII values are minted under its own id (as Vault.Change does).
  defp owner!(tag) do
    id = Ash.UUID.generate()

    vals =
      for {name, vault} <- [full_name: :pii_name, emails: :pii_email, phones: :pii_phone], into: %{} do
        plain = "#{tag}-#{name}-SECRET"
        {:ok, token} = Vault.store_field(id, vault, name, plain, @repo)
        {name, {token, plain}}
      end

    %{id: id, vals: vals}
  end

  defp record(owner) do
    struct(Person, Map.merge(%{id: owner.id}, Map.new(owner.vals, fn {n, {t, _}} -> {n, Masked.new(t, n)} end)))
  end

  # `holder` keeps its own :emails and :phones but its :full_name cell holds `victim`'s token.
  defp planted(holder, victim), do: %{record(holder) | full_name: Masked.new(elem(victim.vals.full_name, 0), :full_name)}

  defp resolve(rec, plane, opts \\ []) do
    resolve_on_plane(rec, Person, plane, Keyword.merge([repo: @repo, grant: DenyAll], opts))
  end

  defp victim_plain(v), do: elem(v.vals.full_name, 1)

  defp assert_no_leak(resolved, victim) do
    refute inspect(resolved, limit: :infinity) =~ victim_plain(victim)
    refute inspect(resolved, limit: :infinity) =~ elem(victim.vals.full_name, 0)
  end

  # --- T-R1 per plane --------------------------------------------------------------------------------------

  describe "T-R1 a planted foreign token masks on every plane (cross-org included)" do
    setup do
      %{victim: owner!("victim"), holder: owner!("holder")}
    end

    test "tenant plane: the planted value is ••••, the holder's OWN values are clear", %{victim: v, holder: h} do
      out = resolve(planted(h, v), :tenant)

      assert_plane_masked!(out.full_name, victim_plain(v))
      assert_no_leak(out, v)
      # POSITIVE CONTROL: the same record's own tokens resolve clear on the same plane
      assert_plane_clear!(out.emails, elem(h.vals.emails, 1))
      assert_plane_clear!(out.phones, elem(h.vals.phones, 1))
      # and an untampered record of the holder is clear for ITS full_name
      assert_plane_clear!(resolve(record(h), :tenant).full_name, elem(h.vals.full_name, 1))
    end

    test "operator WITH a grant on the holder: still ••••, never the victim's plaintext", %{victim: v, holder: h} do
      out = resolve(planted(h, v), :operator, grant: AllowAll)

      assert_plane_masked!(out.full_name, victim_plain(v))
      assert_no_leak(out, v)
      # POSITIVE CONTROL: the grant is live: the holder's own value is clear under it
      assert_plane_clear!(out.emails, elem(h.vals.emails, 1))
    end

    test "operator WITHOUT a grant: ••••", %{victim: v, holder: h} do
      out = resolve(planted(h, v), :operator, grant: DenyAll)
      assert_plane_masked!(out.full_name, victim_plain(v))
      assert_plane_masked!(out.emails)
      assert_no_leak(out, v)
    end

    test "API-key operator (no impersonation) with a grant: the planted field is ABSENT, the own field is clear", %{victim: v, holder: h} do
      [out] =
        PiiResolution.resolve([planted(h, v)], Person, %{plane: :operator}, repo: @repo, grant: AllowAll)

      assert %Ash.ForbiddenField{field: :full_name} = out.full_name
      assert out.emails == elem(h.vals.emails, 1)
      assert_no_leak(out, v)
    end

    test "impersonation: ••••", %{victim: v, holder: h} do
      [out] =
        PiiResolution.resolve([planted(h, v)], Person, %{plane: :operator, impersonation: %{session_id: "s"}},
          repo: @repo,
          grant: AllowAll
        )

      assert_plane_masked!(out.full_name, victim_plain(v))
      assert_no_leak(out, v)
    end

    test "AI egress with the host opt-in and a live grant: the planted value stays ••••", %{victim: v, holder: h} do
      [out] =
        PiiResolution.resolve([planted(h, v)], Person, %{plane: :tenant},
          repo: @repo,
          grant: AllowAll,
          egress: true,
          grant_egress?: true
        )

      assert_plane_masked!(out.full_name, victim_plain(v))
      assert_no_leak(out, v)
      # POSITIVE CONTROL: the same opt-in + grant DOES clear the holder's own value
      assert out.emails == elem(h.vals.emails, 1)
    end

    test "a FIELD swap inside one record (its :emails token set as :full_name) masks too", %{holder: h} do
      swapped = %{record(h) | full_name: Masked.new(elem(h.vals.emails, 0), :full_name)}
      out = resolve(swapped, :tenant)
      assert_plane_masked!(out.full_name, elem(h.vals.emails, 1))
      assert_plane_clear!(out.emails, elem(h.vals.emails, 1))
    end

    test "DB path: a token planted by a raw UPDATE on the domain column masks on the tenant plane" do
      a = create_patient("MRN-VICTIM-RAW")
      b = create_patient("MRN-HOLDER-RAW")
      a_token = raw_mrn(a)

      @repo.query!("UPDATE pat_patient SET pii_pat_mrn = $1 WHERE pat_id = $2", [a_token, Ecto.UUID.dump!(b.id)])

      b_read = reload(b)
      assert %Masked{token: ^a_token} = b_read.mrn

      out = resolve_on_plane(b_read, Patient, :tenant, repo: @repo)
      assert_plane_masked!(out.mrn, "MRN-VICTIM-RAW")
      refute inspect(out) =~ "MRN-VICTIM-RAW"

      # POSITIVE CONTROL: the victim's own record reveals its own value
      assert_plane_clear!(resolve_on_plane(reload(a), Patient, :tenant, repo: @repo).mrn, "MRN-VICTIM-RAW")
    end
  end

  defp create_patient(mrn) do
    Patient
    |> Ash.Changeset.for_create(:create, %{org_id: Ash.UUID.generate(), mrn: mrn, dob: ~D[1990-01-01]})
    |> Ash.create!()
  end

  defp reload(p) do
    require Ash.Query

    Patient
    |> Ash.Query.filter(id == ^p.id)
    |> Ash.Query.ensure_selected([:full_name, :mrn, :dob])
    |> Ash.read_one!()
  end

  defp raw_mrn(p) do
    %{rows: [[v]]} = @repo.query!("SELECT pii_pat_mrn FROM pat_patient WHERE pat_id = $1", [Ecto.UUID.dump!(p.id)])
    v
  end

  # --- T-R3 report -------------------------------------------------------------------------------------------

  describe "T-R3 a mismatch is reported once per record and field, locatable, tokenless" do
    test "one report per holding record (a repeat adds none); the log names resource, field, record; telemetry has the reason only" do
      v = owner!("victim")
      h1 = owner!("h1")
      h2 = owner!("h2")
      test_pid = self()
      id = {__MODULE__, :report}

      :telemetry.attach(id, [:samen, :core, :read, :error], fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)

      victim_token = elem(v.vals.full_name, 0)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          out =
            PiiResolution.resolve([planted(h1, v), planted(h2, v), planted(h1, v)], Person, %{plane: :tenant, org_id: Ash.UUID.generate()},
              repo: @repo
            )

          assert Enum.all?(out, &match?(%Masked{}, &1.full_name))
        end)

      assert_receive {:failure, %{read: :vault_token_unbound, cause: "foreign_subject"} = meta}
      assert_receive {:failure, %{read: :vault_token_unbound, cause: "foreign_subject"}}
      refute inspect(meta) =~ "vt_"
      refute inspect(meta) =~ h1.id
      refute_receive {:failure, %{read: :vault_token_unbound}}, 50

      # An operator can find the rows from the log line alone.
      for h <- [h1, h2] do
        assert log =~ "resource=#{inspect(Person)} field=full_name record=#{h.id}"
      end

      refute log =~ v.id, "the victim is not named"
      refute log =~ victim_token
      refute log =~ "vt_"
    end

    test "a non-UUID record id and a hostile field are never put in the log line verbatim" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Samen.Observability.Failure.report(:read, :vault_token_unbound, nil, :foreign_subject,
            locate: [resource: Person, field: :"x\ny=1", record: "9\nforged=1"]
          )

          Samen.Observability.Failure.report(:read, :vault_token_unbound, nil, :foreign_subject,
            locate: [resource: Person, field: :full_name, record: 42]
          )
        end)

      assert log =~ "record=invalid"
      assert log =~ "field=x?y?1"
      refute log =~ "forged"
      assert log =~ "field=full_name record=42"
    end

    test "CONTROL: an all-bound page reports nothing" do
      o = owner!("clean")
      test_pid = self()
      id = {__MODULE__, :clean}

      :telemetry.attach(id, [:samen, :core, :read, :error], fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)

      [out] = PiiResolution.resolve([record(o)], Person, %{plane: :tenant}, repo: @repo)
      assert out.emails == elem(o.vals.emails, 1)
      refute_receive {:failure, _}, 50
    end

    test "a field mismatch (same subject, other field) reports :field_mismatch" do
      h = owner!("h")
      test_pid = self()
      id = {__MODULE__, :field}

      :telemetry.attach(id, [:samen, :core, :read, :error], fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)

      swapped = %{record(h) | full_name: Masked.new(elem(h.vals.emails, 0), :full_name)}

      log = ExUnit.CaptureLog.capture_log(fn -> PiiResolution.resolve([swapped], Person, %{plane: :tenant}, repo: @repo) end)

      assert_receive {:failure, %{read: :vault_token_unbound, cause: "field_mismatch"}}
      assert log =~ "resource=#{inspect(Person)} field=full_name record=#{h.id}"
    end
  end

  # --- the reveal chokepoint ---------------------------------------------------------------------------------

  describe "Vault.reveal/3 :field" do
    test "the matching {vault, field} reveals; a mismatch is :field_mismatch; absent = no check" do
      o = owner!("o")
      {t, plain} = o.vals.emails

      assert {:ok, ^plain} = Vault.reveal(Masked.new(t, :emails), @repo, subject_id: o.id, field: {"pii_email", "emails"})
      assert {:ok, ^plain} = Vault.reveal(Masked.new(t, :emails), @repo, field: {:pii_email, :emails})
      assert {:error, :field_mismatch} = Vault.reveal(Masked.new(t, :emails), @repo, field: {"pii_email", "full_name"})
      assert {:error, :field_mismatch} = Vault.reveal(Masked.new(t, :emails), @repo, field: {"pii_name", "emails"})
      assert {:ok, ^plain} = Vault.reveal(Masked.new(t, :emails), @repo)
    end

    test "bound?/3 compares subject, vault and field" do
      o = owner!("o")
      {t, _} = o.vals.emails
      row = @repo.get(Samen.Vault.VaultRow, t)

      assert Vault.bound?(row, o.id, {"pii_email", "emails"})
      assert Vault.bound?(row, o.id, {:pii_email, :emails})
      refute Vault.bound?(row, Ash.UUID.generate(), {"pii_email", "emails"})
      refute Vault.bound?(row, o.id, {"pii_email", "phones"})
      refute Vault.bound?(row, o.id, {"pii_phone", "emails"})
      refute Vault.bound?(nil, o.id, {"pii_email", "emails"})
    end
  end
end
