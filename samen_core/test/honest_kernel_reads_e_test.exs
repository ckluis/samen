defmodule Samen.HonestKernelReadsETest do
  @moduledoc """
  Honest reads, kernel phase E. The masking core (`Samen.Api.PiiResolution`) fails CLOSED when a read under it fails:
  the value stays masked / the bag stays masked, and that is unchanged. What was wrong is that it did so silently, so an
  outage that masked a whole page was indistinguishable from a deliberate mask. Each failure is now reported ONCE per
  call, by name, value-free (no plaintext, no `vt_` token). Each RED case injects a real failure and pairs with a
  positive control through the same seam.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Api.PiiResolution
  alias Samen.CustomFields
  alias Samen.Masked
  alias Samen.Vault
  alias SamenCore.Support.CrmScopeFixture.Person
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)

    test_pid = self()
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:samen, :core, :read, :error], fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

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

  # The vault-row prefetch (`repo.all`) fails with a database error; a single-row read still works.
  defmodule PrefetchDownRepo do
    @moduledoc false
    def all(_query), do: raise(DBConnection.ConnectionError, "connection not available")
    def get(schema, id), do: SamenCore.TestRepo.get(schema, id)
  end

  # The custom-field catalog read (`repo.all`) fails with a database error.
  defmodule CatalogDownRepo do
    @moduledoc false
    def all(_query), do: raise(DBConnection.ConnectionError, "connection not available")
  end

  # --- fixtures ------------------------------------------------------------------------------------------

  defp owner!(tag) do
    id = Ash.UUID.generate()

    vals =
      for {name, vault} <- [full_name: :pii_name, emails: :pii_email, phones: :pii_phone], into: %{} do
        plain = "#{tag}-#{name}-SECRET"
        {:ok, token} = Vault.store_field(id, vault, name, plain, Repo)
        {name, {token, plain}}
      end

    %{id: id, vals: vals}
  end

  defp record(owner),
    do: struct(Person, Map.merge(%{id: owner.id}, Map.new(owner.vals, fn {n, {t, _}} -> {n, Masked.new(t, n)} end)))

  defp page, do: Enum.map(1..3, fn i -> owner!("row#{i}") end)

  defp count(log, name), do: length(Regex.scan(~r/read failed read=#{name} /, log))

  defp drain_failures(name, acc \\ []) do
    receive do
      {:failure, %{read: ^name} = meta} -> drain_failures(name, [meta | acc])
      {:failure, _other} -> drain_failures(name, acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  # --- PiiResolution: a failed reveal ----------------------------------------------------------------------

  describe "PiiResolution.resolve — a reveal that FAILED is reported once per call, and stays masked" do
    test "RED: a KMS outage masks the whole page on the tenant plane; ONE report by name, no value, no token" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      Samen.Kms.FileBacked.simulate_outage(true)

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: Repo)
          # fail closed, exactly as before: every value of every row is masked
          assert Enum.all?(out, fn r -> Enum.all?([:full_name, :emails, :phones], &match?(%Masked{}, Map.get(r, &1))) end)
        end)

      # 3 rows x 3 fields fail; ONE log line and ONE event
      assert count(log, "pii_resolution_reveal") == 1
      assert log =~ "cause=unavailable"
      assert [%{cause: "unavailable"}] = drain_failures(:pii_resolution_reveal)

      # the report carries neither a plaintext nor a token (both appear in `inspect` of the values it could have leaked)
      refute log =~ "SECRET"
      refute log =~ "vt_"
    end

    test "RED: the same outage on an operator WITH a grant still omits the field (fail closed unchanged), reported once" do
      [o | _] = page()
      Samen.Kms.FileBacked.simulate_outage(true)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([record(o)], Person, %{plane: :operator, org_id: Ash.UUID.generate()}, repo: Repo, grant: AllowAll)
          assert %Ash.ForbiddenField{} = out.full_name
        end)

      assert count(log, "pii_resolution_reveal") == 1
      refute log =~ "SECRET"
    end

    test "POSITIVE CONTROL: with the KMS up the same page is clear and nothing is reported" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: Repo)
          assert Enum.zip(owners, out) |> Enum.all?(fn {o, r} -> r.full_name == elem(o.vals.full_name, 1) end)
        end)

      refute log =~ "pii_resolution_reveal"
      assert drain_failures(:pii_resolution_reveal) == []
    end

    test "a SHREDDED subject is a fact about the data, not a failure: masked and not reported (control for the denial arm)" do
      [o | _] = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      assert {:ok, _} = Vault.shred(o.id)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([record(o)], Person, actor, repo: Repo)
          assert %Masked{} = out.full_name
        end)

      refute log =~ "pii_resolution_reveal"
      assert drain_failures(:pii_resolution_reveal) == []
    end
  end

  # --- PiiResolution: a failed vault-row prefetch -----------------------------------------------------------

  describe "PiiResolution.prefetch — a failed vault-row prefetch is reported once" do
    test "RED: the prefetch read fails -> ONE report by name; the value is still the correct one (per-value read)" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: PrefetchDownRepo)
          # the prefetch only saves reads: the per-value read answers, so nothing is wrongly masked or revealed
          assert Enum.zip(owners, out) |> Enum.all?(fn {o, r} -> r.full_name == elem(o.vals.full_name, 1) end)
        end)

      assert count(log, "pii_resolution_vault_rows") == 1
      assert log =~ "cause=DBConnection.ConnectionError"
      assert [%{cause: "DBConnection.ConnectionError"}] = drain_failures(:pii_resolution_vault_rows)
      refute log =~ "SECRET"
      refute log =~ "vt_"
      refute log =~ "connection not available"
    end

    test "POSITIVE CONTROL: the healthy repo prefetches without a report" do
      owners = page()

      log =
        capture_log(fn ->
          PiiResolution.resolve(Enum.map(owners, &record/1), Person, %{plane: :tenant, org_id: Ash.UUID.generate()}, repo: Repo)
        end)

      refute log =~ "pii_resolution_vault_rows"
      assert drain_failures(:pii_resolution_vault_rows) == []
    end
  end

  # --- PiiResolution: an unreadable custom-field catalog ----------------------------------------------------

  describe "PiiResolution bag — an unreadable pii_declared catalog masks the whole bag AND says so" do
    @table "tcf_widget"
    @key "care_note"
    @secret "alice@example.com"

    defp define!(org_id) do
      {:ok, _} =
        CustomFields.define_field(
          %{
            org_id: org_id,
            table_name: @table,
            field_name: @key,
            type: :string,
            pii_declared: true,
            erasure_specs: [%{table_name: @table, bag_column: "tcf_custom", subject_column: "tcf_id", org_column: "tcf_org_id"}]
          },
          Repo
        )
    end

    defp widget(org_id),
      do: struct(Widget, %{id: Ecto.UUID.generate(), name: "w", org_id: org_id, custom: %{@key => @secret, "tier" => "gold"}})

    defp op(org), do: %{plane: :operator, org_id: org, impersonation: %{session_id: "s"}}

    test "RED: the catalog read fails -> the WHOLE bag is masked (unchanged), ONE report by name, no value" do
      org = Ash.UUID.generate()
      define!(org)

      log =
        capture_log(fn ->
          out = PiiResolution.resolve([widget(org), widget(org), widget(org)], Widget, op(org), repo: CatalogDownRepo, grant: DenyAll)
          assert Enum.all?(out, fn r -> match?(%Masked{}, r.custom[@key]) and match?(%Masked{}, r.custom["tier"]) end)
        end)

      assert count(log, "pii_resolution_declared_keys") == 1
      assert log =~ "cause=DBConnection.ConnectionError"
      assert [%{cause: "DBConnection.ConnectionError"}] = drain_failures(:pii_resolution_declared_keys)
      refute log =~ @secret
      refute log =~ "gold"
    end

    test "POSITIVE CONTROL: a readable catalog masks only the declared key and reports nothing" do
      org = Ash.UUID.generate()
      define!(org)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([widget(org)], Widget, op(org), repo: Repo, grant: DenyAll)
          assert %Masked{} = out.custom[@key]
          assert out.custom["tier"] == "gold"
        end)

      refute log =~ "pii_resolution_declared_keys"
      assert drain_failures(:pii_resolution_declared_keys) == []
    end
  end
end
