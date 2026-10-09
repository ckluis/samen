defmodule Samen.Observability.OtlpExporterTest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 2) — the `--deploy` runtime layer maps `OTEL_EXPORTER_OTLP_ENDPOINT`
  to the OTLP trace exporter, and is FAIL-HONEST (ADR-024): an endpoint set without a loadable
  `opentelemetry_exporter` RAISES at boot instead of booting an app that drops every span.

  Proven twice: on `Samen.Observability.otlp_runtime_config/2` directly, and by EVALUATING the
  generated `config/runtime.exs` for `:prod` with `Config.Reader` (the same reader a release
  boots through), so a template that stopped calling the mapping fails here.
  """
  use ExUnit.Case, async: false

  alias Samen.Gen.App, as: Gen
  alias Samen.Observability

  describe "otlp_runtime_config/2" do
    test "no endpoint (unset or empty) → no config: the :none default stands" do
      assert Observability.otlp_runtime_config(nil) == []
      assert Observability.otlp_runtime_config("") == []
    end

    test "RED: an endpoint without a loadable opentelemetry_exporter RAISES, naming the dep" do
      err =
        assert_raise ArgumentError, fn ->
          Observability.otlp_runtime_config("https://otel.example:4318",
            loadable?: fn _ -> false end
          )
        end

      assert err.message =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
      assert err.message =~ "opentelemetry_exporter"
      assert err.message =~ "fail-honest"
    end

    test "RED (real): samen_core does not ship the exporter dep, so the real check raises" do
      refute Code.ensure_loaded?(:opentelemetry_exporter)

      assert_raise ArgumentError, fn ->
        Observability.otlp_runtime_config("https://otel.example:4318")
      end
    end

    test "POSITIVE CONTROL: with the exporter loadable, the OTLP exporter is selected" do
      config =
        Observability.otlp_runtime_config("https://otel.example:4318",
          loadable?: fn _ -> true end
        )

      assert config[:opentelemetry][:traces_exporter] == :otlp
      assert config[:opentelemetry_exporter][:otlp_endpoint] == "https://otel.example:4318"
    end
  end

  describe "the generated --deploy config/runtime.exs" do
    @secrets %{
      "DATABASE_URL" => "postgres://u:p@db.example/acme",
      "SECRET_KEY_BASE" => String.duplicate("k", 64),
      "PHX_HOST" => "acme.example",
      "SAMEN_KMS_KEY_ID" => "kms-key",
      "SAMEN_KMS_REGION" => "eu-west-1"
    }

    setup do
      b =
        Gen.bindings(
          Gen.build_spec(
            module: "Acme",
            prefix: "ac",
            abbrev: "acm",
            target: Gen.default_target(),
            deploy: true
          )
        )

      runtime =
        Enum.find_value(Samen.Gen.Templates.files(true, true, true), fn {path, template} ->
          if Gen.render(path, b) == "config/runtime.exs", do: Gen.render(template, b)
        end)

      dir =
        Path.join(System.tmp_dir!(), "samen_otlp_runtime_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "runtime.exs")
      File.write!(path, runtime)

      keys = Map.keys(@secrets) ++ ["OTEL_EXPORTER_OTLP_ENDPOINT"]
      prev = Map.new(keys, &{&1, System.get_env(&1)})
      System.put_env(@secrets)

      on_exit(fn ->
        File.rm_rf!(dir)

        Enum.each(prev, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      %{path: path}
    end

    test "POSITIVE CONTROL: no endpoint → the prod runtime config loads with no exporter set", %{
      path: path
    } do
      System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
      config = Config.Reader.read!(path, env: :prod)
      refute Keyword.has_key?(config, :opentelemetry_exporter)
      refute get_in(config, [:opentelemetry, :traces_exporter])
    end

    test "RED: an endpoint without the exporter dep makes the prod runtime config RAISE", %{
      path: path
    } do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://otel.example:4318")

      assert_raise ArgumentError, ~r/opentelemetry_exporter/, fn ->
        Config.Reader.read!(path, env: :prod)
      end
    end
  end
end
