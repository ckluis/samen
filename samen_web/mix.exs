defmodule SamenWeb.MixProject do
  use Mix.Project

  # samen_web — the FRAMEWORK UI library (ADR-009). It promotes the inherited-80%
  # product UI (the component kit + the CRM/Billing/Support LiveViews + the two-plane
  # masking) out of the driftwood-local `driftwood_web` and into a shared path-dep lib
  # that EVERY vertical inherits by mounting, not by copying 11 LiveViews.
  #
  # It depends on phoenix_live_view/phoenix_html/phoenix (the web deps) + samen_core
  # (the pure kernel, path dep). samen_core gains NO web dep — the web dep lives HERE,
  # so the kernel's 842-test suite + verifier gate stay green by construction.
  #
  # In :test it ships its OWN test-support host (Samen.WebTest.{Repo,Crm,Billing,Support})
  # so the render tests exercise real materialized scope resources with NO dependency on
  # any vertical — the two-plane masking guarantee is proven by a framework-local test.
  def project do
    [
      app: :samen_web,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # ExDoc — moduledoc coverage is ~100%; `mix docs` emits HTML API docs into `doc/`
      # (gitignored, dev-only, never committed). `--warnings-as-errors` compile / CI are
      # unaffected: ex_doc is `only: :dev, runtime: false`.
      name: "samen_web",
      source_url: "https://github.com/ckluis/samen",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # ADR-038 §6.1 — supervise the Hammer rate-limit backend (a stable ETS-table owner
      # so per-account/per-IP counters survive across requests). samen_web-only (INV-4).
      mod: {Samen.Web.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The pure kernel — %Masked{}, Samen.Scope, Samen.Api.PiiResolution, the scope
      # blueprints. No web dep flows back into it.
      {:samen_core, path: "../samen_core"},
      # Web deps — the reason this lib exists separately from samen_core.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      # AshPhoenix.Form — the A2 form-primitive contract (ADR-016 §2): `simple_form/1`
      # is `AshPhoenix.Form`-backed (create/edit + inline validation errors).
      {:ash_phoenix, "~> 2.3"},
      {:jason, "~> 1.4"},
      # ADR-035 §5 A6/§7 — the OPTIONAL OIDC module's protocol library (Google the
      # reference IdP). A protocol implementation, NOT a vendor SDK — what
      # ash_authentication itself uses. Its HTTP client (`req`) + JWT (`jose`) deps
      # are all OPTIONAL: assent compiles standalone, and `Samen.Web.Auth.Oidc`
      # resolves the strategy lazily behind `Code.ensure_loaded?/1`, so an app that
      # never enables OIDC (or has not wired a live IdP) simply fail-honests
      # `{:error, :not_configured}` — the module-absent / unconfigured contract.
      {:assent, "~> 0.3"},
      # ADR-035 §5 A7/§7 — the 2FA/TOTP module's protocol library (RFC 6238):
      # secret generation, `otpauth://` provisioning URIs, and time-window code
      # comparison. Pure OTP `:crypto` under the hood, no transitive HTTP/JWT
      # deps (unlike `assent`) — `Samen.Web.Auth.Totp` is the ONLY caller
      # (INV-4: `samen_core` never references it; the kernel-side atomic
      # DB mutation in `Samen.Identity.Totp` takes the validity decision as an
      # injected pure function instead).
      {:nimble_totp, "~> 1.0"},
      # ADR-035 §4.5 / ADR-037 §5.14 / ADR-038 §6 — auth-surface + webhook-ingress
      # rate limiting (narrow ADOPT: auth + webhook ingress only). `ash_rate_limiter`
      # is PINNED == 1.0.0 (the retired-2.0.0 mishap, ADR-037 §5.14); Hammer `~> 7.0`
      # is the multi-node counter backend behind `Samen.Web.RateLimit`. These live in
      # `samen_web` ONLY — `samen_core/mix.exs` gains ZERO rate-limiter deps (INV-4).
      # The package's resource-level `rate_limit` DSL and Change/Preparation hooks are
      # DELIBERATELY NOT USED (they would compile limits into core resources); the dep
      # is present per the narrow-ADOPT contract, enforcement is the manual-plug seam.
      {:ash_rate_limiter, "== 1.0.0"},
      {:hammer, "~> 7.0"},
      # Test-support host deps (materialize the scope blueprints against a scratch repo):
      {:ash, "== 3.31.2"},
      {:ash_postgres, "== 2.10.0"},
      {:simple_sat, "~> 0.1"},
      # StreamData — WS-F4 QA property tests for the RFC-4180 CSV round-trip +
      # formula-injection neutralization (`Samen.Web.Csv`). (samen_core, a path dep,
      # already brings stream_data as a prod dep, so it cannot be :test-only here.)
      {:stream_data, "== 1.3.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  defp aliases do
    [
      # `mix test` sets up the scratch samen_web_test DB (drop/create/migrate) then runs.
      test: ["samen_web.test_setup", "test"]
    ]
  end
end
