defmodule SamenCore.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :samen_core,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Samen foundry kernel: self-qualifying storage, machine catalog, PII vault.",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SamenCore.Application, []}
    ]
  end

  # test/support holds the kernel's fixture resources, domain, and repo. dev also
  # needs them so `mix ash.codegen` can introspect resources to generate the
  # migrations used by the DDL / no-INHERITS assertions.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Versions pinned in spikes/s00_smoke/VERSIONS.md (Elixir 1.20.2 / OTP 29).
  defp deps do
    [
      {:ash, "== 3.29.3"},
      {:ash_postgres, "== 2.10.0"},
      {:spark, "== 2.7.2"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.2"},
      {:jason, "~> 1.4"},
      {:stream_data, "== 1.3.0"}
    ]
  end

  defp aliases do
    # test/test_helper.exs owns the full Repo lifecycle (storage_down + storage_up
    # + migrate) so the schema always matches the generated migrations. We do NOT
    # add ecto.create/migrate here — doing so double-migrates and races the helper.
    []
  end

  defp package do
    [
      name: "samen_core",
      files: ~w(lib priv mix.exs README.md),
      licenses: ["Proprietary"]
    ]
  end
end
