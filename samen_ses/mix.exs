defmodule SamenSes.MixProject do
  use Mix.Project

  # samen_ses — the first-party-but-separate AWS SES delivery adapter package
  # (ADR-038 §8.1; T94/C1, the SECOND reference ESP behind the M1 ruling).
  # Implements `Samen.Delivery.Provider` + the shared
  # `Samen.Delivery.ProviderConformanceCase` harness (samen_core, T27) UNCHANGED.
  # Path-deps on samen_core ONLY (never samen_web — ADR-038 §8.1); every vendor/
  # HTTP/signing dependency lives HERE, never in samen_core (INV-4).
  #
  # NOT inbound-capable (ADR-038 §4.5 adapter split: "samen_ses (SNS-envelope
  # webhook verification, including the SNS subscription-confirmation handshake,
  # inside the adapter; no inbound)"). `deliver/2`'s HTTP wiring is real (SigV4-
  # signed SESv2 `SendEmail` request building, response parsing, receipt shape)
  # but its RECIPIENT RESOLUTION is an operator TODO (`config[:resolve_recipient]`,
  # mirrors the samen_postmark/Smtp/Api skeleton precedent): nothing in this
  # package can know how a given host resolves a `to_subscriber_id` token to a
  # plaintext email, so today deliver/2 is honestly `{:error, :not_implemented}`
  # in real (non-fixture) use until a host wires that function.
  # `verify_and_parse_event/3` needs no such host glue and is fully implemented:
  # real SNS envelope signature verification (RSA-SHA1/SHA256 over the AWS
  # canonical string, verified against the X.509 cert fetched from
  # `SigningCertURL`) plus the SNS subscription-confirmation handshake.
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
      app: :samen_ses,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # test/fixtures/conformance.exs is data loaded via Code.eval_file by the
      # shared harness, not an ExUnit test file — ignore it the same way
      # samen_postmark's own test/fixtures/ carve-out does (Elixir 1.20
      # otherwise warns about any test/ file matching neither
      # :test_load_filters nor :test_ignore_filters, and --warnings-as-errors
      # treats that as a failure).
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key, :crypto]
    ]
  end

  defp deps do
    [
      # Issue #73: dialyzer runs in the default ./ci.sh (dev/test only, never shipped).
      {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false},
      {:samen_core, path: "../samen_core"},
      # House HTTP client for adapter packages (ADR-038 §8.2), pinned per the ADR.
      {:req, "~> 0.5"},
      # ADR-038 §8.2: "samen_ses may additionally carry an AWS SigV4 signing dep
      # (its own package, allowed — vendor deps live in adapter packages by
      # definition)." Pure-Erlang, zero transitive deps, used to sign the real
      # SESv2 SendEmail request (Transport.live/1) — never referenced outside
      # this package.
      {:aws_signature, "~> 0.4"}
    ]
  end
end
