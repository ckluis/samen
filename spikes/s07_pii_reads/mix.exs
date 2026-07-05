defmodule S07PiiReads.MixProject do
  use Mix.Project

  def project do
    [
      app: :s07_pii_reads,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # S0.7 is a pure AST-analysis spike. It walks Elixir source with the
  # stdlib (`Code.string_to_quoted/2` + `Macro.prewalk/3`) and needs no
  # Ash/Postgres/Oban runtime. No external deps by design — this keeps the
  # feasibility signal about the AST walker, not about a framework.
  defp deps do
    []
  end
end
