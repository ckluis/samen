defmodule Samen.GenDeployBootabilityTest do
  @moduledoc """
  P2-A DEPLOY BOOTABILITY (ADR-045 §4.2 + §2.1) — the sabotage-replayable twin of the
  `--deploy` gen probe (`priv/gen_app_deploy_probe.exs`), which runs under `mix run` and so
  cannot be targeted by the `mix test`-based sabotage harness. Each guarantee below is proven
  here as a NAMED `mix test` assertion the harness can flip:

    * **O5 / X6** — the `--deploy` KMS posture selects `Samen.Kms.AwsKmsDynamo`, a raise-only
      SKELETON. The framework prod BOOT GUARD (`Samen.Kms.assert_prod_adapter_ready!/1`) must
      REFUSE to boot in prod rather than let the app come up green and 500 on every vault op.
    * **O4** — the generated `aud_event` migration must derive its `REVOKE` role, never ship the
      hardcoded developer laptop role `"clank"` into an adopter's prod migration.
    * **§2.1** — the generator must emit a `config/prod.exs` so a prod `import_config` does not
      abort, and that file must load under `Config.Reader` in `:prod`.

  All assertions carry a positive control (anti-tautology): a test that cannot fail is a bug.
  """
  use ExUnit.Case, async: false

  alias Samen.Gen.App, as: Gen
  alias Samen.Gen.Templates

  # A fixed, hermetic spec (no registry / filesystem touch — mirrors templates_parity_test).
  defp spec(opts \\ []) do
    Gen.build_spec(
      [module: "Acme", prefix: "ac", abbrev: "acm", target: Gen.default_target()]
      |> Keyword.merge(opts)
    )
  end

  defp render_file(files, path, spec) do
    {^path, template} = Enum.find(files, fn {p, _} -> p == path end)
    Gen.render(template, Gen.bindings(spec))
  end

  describe "O5 / X6 — the prod KMS boot guard (Samen.Kms.assert_prod_adapter_ready!/1)" do
    setup do
      saved = Application.get_env(:samen_core, :kms_adapter)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:samen_core, :kms_adapter, saved),
          else: Application.delete_env(:samen_core, :kms_adapter)
      end)

      :ok
    end

    test "refuses to boot in prod when an unimplemented skeleton KMS adapter is selected (O5)" do
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.AwsKmsDynamo)

      err =
        assert_raise RuntimeError, fn ->
          Samen.Kms.assert_prod_adapter_ready!(fn -> :prod end)
        end

      # The error must be ACTIONABLE: name the adapter and list the ADR-001 §8.2 obligations,
      # so an operator knows exactly why the app refuses to boot and what to do.
      assert err.message =~ "AwsKmsDynamo"
      assert err.message =~ "UNIMPLEMENTED SKELETON"
      assert err.message =~ "ADR-001 §8.2"
      assert err.message =~ "refuses to boot"
    end

    test "admits a working KMS adapter in prod — positive control (O5)" do
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

      assert :ok = Samen.Kms.assert_prod_adapter_ready!(fn -> :prod end)
    end

    test "is a no-op in dev even with a skeleton adapter selected — env-scope control (O5)" do
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.AwsKmsDynamo)

      assert :ok = Samen.Kms.assert_prod_adapter_ready!(fn -> :dev end)
      assert :ok = Samen.Kms.assert_prod_adapter_ready!(fn -> :test end)
    end

    test "AwsKmsDynamo declares itself an unimplemented skeleton; FileBacked does not (O5 marker)" do
      assert Samen.Kms.AwsKmsDynamo.__kms_skeleton__?() == true
      refute function_exported?(Samen.Kms.FileBacked, :__kms_skeleton__?, 0)
    end
  end

  describe "O4 — the generated aud_event migration derives its REVOKE role" do
    test "the generated aud_event migration derives the DB app role, never a hardcoded 'clank' (O4)" do
      files = Templates.files(true, true, true)
      migration = render_file(files, "priv/repo/migrations/20260705020000_aud_event.exs", spec())

      # The defect: `REVOKE UPDATE, DELETE ON aud_event FROM clank` — a developer's laptop role.
      refute migration =~ "clank",
             "the generated aud_event migration must not ship a hardcoded 'clank' laptop role"

      # Positive control: the role IS resolved (the derivation seam is present), so the refute
      # above is meaningful — the REVOKE still happens, just against a derived role.
      assert migration =~ "REVOKE UPDATE, DELETE ON aud_event"
      assert migration =~ ":aud_event_app_role"
      assert migration =~ "Keyword.get(:username)" or migration =~ ":username"
    end
  end

  describe "§2.1 — the generator emits a loadable config/prod.exs" do
    test "config/prod.exs is emitted for the headless, web, and deploy sets (§2.1)" do
      for files <- [Templates.files(false, false, false), Templates.files(true, false, false), Templates.files(true, true, true)] do
        paths = Enum.map(files, &elem(&1, 0))
        assert "config/prod.exs" in paths, "every generated app set must emit config/prod.exs"
      end
    end

    test "the emitted config/prod.exs loads under Config.Reader in :prod without aborting (§2.1)" do
      files = Templates.files(true, true, true)
      rendered = render_file(files, "config/prod.exs", spec())

      dir = System.tmp_dir!() |> Path.join("samen_prod_exs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "prod.exs")

      try do
        File.write!(path, rendered)
        # A prod config-load must not abort (the §2.1 defect was the MISSING file).
        assert is_list(Config.Reader.read!(path, env: :prod))
      after
        File.rm_rf!(dir)
      end
    end
  end
end
