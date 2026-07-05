defmodule S05Vault.MixProject do
  use Mix.Project

  def project do
    [
      app: :s05_vault,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {S05Vault.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Deliberately lean. The vault/KMS crypto is pure OTP :crypto — no Ash, no
  # Cloak dependency (ADR-003 documents why). Ecto + Postgrex give us a real
  # changeset round-trip and a real Postgres table so the PITR/pg_dump red
  # path is executed against actual on-disk data, not a mock.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19 or ~> 1.0"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"}
    ]
  end
end
