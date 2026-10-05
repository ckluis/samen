defmodule SamenAnthropic.MixProject do
  use Mix.Project

  # samen_anthropic — the first-party-but-separate Anthropic AI-provider adapter
  # package (ADR-043 §5.1; T64/D1). Implements `Samen.AI.Provider` for Anthropic's
  # Messages API. Path-deps on samen_core ONLY (never samen_web — the samen_stripe/
  # samen_postmark §8.1 layout precedent); every vendor/HTTP dependency (req) lives
  # HERE, never in samen_core (INV-4; proved by samen_core's own
  # Samen.AI.VendorFreeTest, which asserts zero anthropic/ash_ai references in
  # samen_core/lib + mix.exs and no vendor HTTP client dep there).
  #
  # KEYLESS / FAIL-HONEST (ADR-043 §4; ADR-014/024/026): with NO api_key configured,
  # complete/2 returns {:error, :not_configured} — NEVER a fake {:ok, _}. Anthropic
  # has no embeddings endpoint, so embed/2 is honestly {:error, :not_implemented}
  # (capability absence), never a fabricated vector. The real Messages-API HTTP call
  # (SamenAnthropic.Transport, via req) is exercised for real ONLY behind a host
  # opt-in (SAMEN_AI_LIVE=1, ADR-043 §4) — NEVER in CI. The test suite drives the
  # request-shaping/response-parsing pipeline through an injected fixture transport
  # (the samen_postmark cassette precedent), so `mix test` makes zero live calls.
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
      app: :samen_anthropic,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
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
      # House HTTP client for adapter packages (the ADR-038 §8.2 precedent), used
      # ONLY on the live (SAMEN_AI_LIVE=1) lane — tests inject a fixture transport.
      {:req, "~> 0.5"}
    ]
  end
end
