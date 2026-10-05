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
      # Issue #73: PLT cached in priv/plts (gitignored); pre-existing warnings that are
      # false positives or deliberate code are listed, each with its reason, in
      # .dialyzer_ignore.exs, so the gate fails on NEW warnings only.
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit, :mix],
        # The in-repo framework (samen_core, samen_web) is analysed by its OWN project's run.
        # Kept out of this PLT, a framework change never forces this app's PLT to rebuild (a
        # path dep is invisible to dialyxir's lockfile hash, so it would otherwise go stale).
        # The calls into it that dialyzer then cannot resolve are ignored by a `Samen.`-scoped
        # pattern in .dialyzer_ignore.exs, so an unknown call to anything ELSE still fails.
        plt_ignore_apps: [:samen_core, :samen_web],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
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
      # Issue #73: dialyzer runs in the default ./ci.sh (dev/test only, never shipped).
      {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false},
      {:samen_core, path: "../samen_core"},
      # House HTTP client for adapter packages (ADR-038 §8.2), pinned per the ADR.
      {:req, "~> 0.5"}
    ]
  end
end
