defmodule SamenStripe.MixProject do
  use Mix.Project

  # samen_stripe — the first-party-but-separate Stripe adapter package (ADR-038
  # §8.1; T18/B1). Implements `Samen.Billing.Provider` behind the ADR-038 fail-honest
  # contract. Path-deps on samen_core ONLY (never samen_web — ADR-038 §8.1); every
  # vendor/HTTP dependency (req) lives HERE, never in samen_core (INV-4).
  #
  # This is a SKELETON (B1): every callback is present and unconfigured returns
  # {:error, :not_configured}; configured-but-not-yet-wired returns
  # {:error, :not_implemented} (real HTTP dispatch + Stripe signature verification
  # are T19/T20/T21's scope — ADR-038 §3, consumer map).
  def project do
    [
      app: :samen_stripe,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      # House HTTP client for adapter packages (ADR-038 §8.2), pinned per the ADR.
      {:req, "~> 0.5"}
    ]
  end
end
