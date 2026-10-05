defmodule Demo.MixProject do
  use Mix.Project

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
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Demo.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Issue #73: dialyzer runs in the default ./ci.sh (dev/test only, never shipped).
      {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false},
      {:samen_core, path: "../samen_core"},
      # Phoenix + LiveView for the HEEx %Masked{} rendering proof (T1.9 acceptance)
      {:phoenix, "~> 1.8.9"},
      {:phoenix_live_view, "~> 1.2.9"},
      {:phoenix_html, "~> 4.1"},
      # Stream-data for property tests (T1.9 acceptance)
      {:stream_data, "== 1.3.0"},
      # simple_sat: Ash policy authorizer's SAT solver (pure Elixir; no NIF). Needed
      # by the mounted Identity scope's org-scope + RBAC policies (T3.1).
      {:simple_sat, "~> 0.1"},
      # AshJsonApi: the public /api/v1 surface (T3.11; plan OD-6 — AshJsonApi ONLY).
      # Field exposure is opt-in via the `json_api` DSL (allowlist serialization);
      # the same Ash policy stack (org-scope + RBAC + reveal-grant) gates the API.
      {:ash_json_api, "~> 1.7"}
    ]
  end

  defp aliases do
    []
  end
end
