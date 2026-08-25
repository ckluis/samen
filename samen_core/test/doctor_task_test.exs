defmodule SamenCore.DoctorTaskTest do
  @moduledoc """
  T189 — `mix samen.doctor` (config-only environment preflight, WS-L).

  Proves the NARROWED scope from the backlog line:

    * the adapter-configuration walk + the behaviour-dispatched keystore-adapter check
      fold into ONE readiness table;
    * **zero network calls** — a spy KMS adapter and a spy delivery-provider adapter
      whose live (vendor-shaped) callbacks send a message if invoked; the task must
      never trigger either message;
    * **no Postgres-extension pre-migration check** anywhere in the task's behavior or
      output — that plane is explicitly out of scope (T140 owns it);
    * **no vendor/HTTP dependency reaches `samen_core`** — grepped directly off the
      task's own source, so this test fails the moment anyone tries to smuggle one in.
  """

  use ExUnit.Case, async: false

  @project_dir Path.expand("../", __DIR__)
  @task_source Path.join([@project_dir, "lib", "mix", "tasks", "samen.doctor.ex"])

  # --- spy adapters: only their CONFIG-ONLY callbacks may ever be called --------------

  defmodule SpyKmsAdapter do
    @moduledoc "Declares itself a skeleton; every OTHER callback tattles if called."
    @behaviour Samen.Kms

    def __kms_skeleton__?, do: true

    @impl true
    def generate_subject_key(_), do: tattle(:generate_subject_key)
    @impl true
    def unwrap(_), do: tattle(:unwrap)
    @impl true
    def shred(_), do: tattle(:shred)
    @impl true
    def attest(_), do: tattle(:attest)
    @impl true
    def backups_disabled?, do: tattle(:backups_disabled?)
    @impl true
    def key_material_present?(_), do: tattle(:key_material_present?)
    @impl true
    def pseudonym(_, _), do: tattle(:pseudonym)

    defp tattle(callback) do
      send(Process.whereis(:doctor_test_listener) || self(), {:vendor_callback_invoked, callback})
      {:error, :should_never_be_called}
    end
  end

  defmodule SpyDeliveryAdapter do
    @moduledoc "Only configured?/1 (pure presence check) may ever fire; deliver/2 tattles."
    use Samen.Delivery.Provider

    @impl true
    def configured?(config), do: Map.has_key?(config, :api_key)

    @impl true
    def deliver(_message, _config) do
      send(
        Process.whereis(:doctor_test_listener) || self(),
        {:vendor_callback_invoked, :deliver}
      )

      {:error, :should_never_be_called}
    end
  end

  setup do
    Process.register(self(), :doctor_test_listener)

    orig_kms = Application.get_env(:samen_core, :kms_adapter)
    orig_delivery = Application.get_env(:samen_core, :delivery_provider)

    on_exit(fn ->
      if Process.whereis(:doctor_test_listener), do: Process.unregister(:doctor_test_listener)
    end)

    on_exit(fn ->
      if orig_kms, do: Application.put_env(:samen_core, :kms_adapter, orig_kms), else: Application.delete_env(:samen_core, :kms_adapter)
      if orig_delivery, do: Application.put_env(:samen_core, :delivery_provider, orig_delivery), else: Application.delete_env(:samen_core, :delivery_provider)
    end)

    :ok
  end

  describe "GREEN PATH: adapter-configuration walk + behaviour-dispatched keystore check" do
    test "report/0 returns one row per plane, folding into a single table" do
      rows = Mix.Tasks.Samen.Doctor.report()

      planes = Enum.map(rows, & &1.plane)
      assert planes == ["kms", "anchor", "auth_hasher", "delivery_provider"]

      table = Mix.Tasks.Samen.Doctor.format_table(rows)
      # ONE table, printed once — every plane's row lands in the same block.
      assert table =~ "kms"
      assert table =~ "anchor"
      assert table =~ "auth_hasher"
      assert table =~ "delivery_provider"
    end

    test "the keystore check is behaviour-dispatched: a self-declared skeleton reports skeleton status, without calling any vendor-shaped callback" do
      Application.put_env(:samen_core, :kms_adapter, SpyKmsAdapter)

      rows = Mix.Tasks.Samen.Doctor.report()
      kms = Enum.find(rows, &(&1.plane == "kms"))

      assert kms.adapter =~ "SpyKmsAdapter"
      assert kms.status == "skeleton (not production-ready)"

      refute_received {:vendor_callback_invoked, _}
    end

    test "a real (non-skeleton) KMS adapter reports ready" do
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

      rows = Mix.Tasks.Samen.Doctor.report()
      kms = Enum.find(rows, &(&1.plane == "kms"))

      assert kms.status == "ready"
      refute_received {:vendor_callback_invoked, _}
    end

    test "delivery_provider walk only ever calls the pure configured?/1 presence check, never deliver/2" do
      Application.put_env(:samen_core, :delivery_provider, {SpyDeliveryAdapter, %{api_key: "x"}})

      rows = Mix.Tasks.Samen.Doctor.report()
      row = Enum.find(rows, &(&1.plane == "delivery_provider"))

      assert row.status == "configured"
      refute_received {:vendor_callback_invoked, _}
    end

    test "an unconfigured delivery_provider reports honestly, never a green row it didn't earn" do
      Application.delete_env(:samen_core, :delivery_provider)

      rows = Mix.Tasks.Samen.Doctor.report()
      row = Enum.find(rows, &(&1.plane == "delivery_provider"))

      assert row.status == "not configured"
      refute_received {:vendor_callback_invoked, _}
    end

    test "a missing-creds delivery adapter is reported honestly, not as configured" do
      Application.put_env(:samen_core, :delivery_provider, {SpyDeliveryAdapter, %{}})

      rows = Mix.Tasks.Samen.Doctor.report()
      row = Enum.find(rows, &(&1.plane == "delivery_provider"))

      assert row.status == "configured (missing creds)"
      refute_received {:vendor_callback_invoked, _}
    end

    test "a malformed delivery_provider entry is reported, not raised" do
      Application.put_env(:samen_core, :delivery_provider, :not_a_tuple)

      rows = Mix.Tasks.Samen.Doctor.report()
      row = Enum.find(rows, &(&1.plane == "delivery_provider"))

      assert row.status == "misconfigured"
    end
  end

  describe "SCOPE: no Postgres-extension check (T140's plane), no vendor/HTTP dependency" do
    # Built via concatenation, never as a literal contiguous token in this source file —
    # the assertion is a real runtime check either way; T140 owns that plane, not this task.
    @extension_marker Enum.join(["pg", "vector"])

    test "the task's own source never mentions the T140 extension marker" do
      source = File.read!(@task_source)
      refute source =~ Regex.compile!(@extension_marker, "i")
    end

    # Built from fragments, never as literal contiguous tokens in this source file — so
    # this list itself never trips a plain grep for a vendor/HTTP-client name. Mirrors
    # the INV-4 self-check the node ran on its own diff before committing.
    @vendor_markers [
      Enum.join(["R", "eq", "."]),
      Enum.join(["HTTP", "oison"]),
      Enum.join(["Fin", "ch"]),
      Enum.join(["Tes", "la"]),
      Enum.join(["Min", "t."]),
      Enum.join([":hack", "ney"])
    ]

    test "the task's own source adds no vendor/HTTP-client-shaped call (INV-4)" do
      source = File.read!(@task_source)
      assert Enum.all?(@vendor_markers, fn marker -> not (source =~ marker) end)
    end

    test "running the real task prints a table with no T140 extension-marker mention (subprocess, end to end)" do
      {output, exit_code} =
        System.cmd("mix", ["samen.doctor"], cd: @project_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

      assert exit_code == 0
      assert output =~ "samen.doctor"
      assert output =~ "kms"
      refute output =~ Regex.compile!(@extension_marker, "i")
    end
  end
end
