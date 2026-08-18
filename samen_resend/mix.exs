defmodule SamenResend.MixProject do
  use Mix.Project

  # samen_resend — the first-party-but-separate Resend delivery adapter package
  # (ADR-038 §8.1; T95/C1, the THIRD reference ESP adapter behind the M1
  # ruling). Implements `Samen.Delivery.Provider` + the shared
  # `Samen.Delivery.ProviderConformanceCase` harness (samen_core, T27)
  # UNCHANGED. Path-deps on samen_core ONLY (never samen_web — ADR-038 §8.1);
  # every vendor/HTTP dependency lives HERE, never in samen_core (INV-4).
  #
  # NOT inbound-capable (ADR-038 §4.5 adapter split: "samen_resend (Svix-style
  # signatures; no inbound)"). `deliver/2`'s HTTP wiring is real (Resend's
  # `POST /emails` REST call, response parsing, receipt shape) but its
  # RECIPIENT RESOLUTION is an operator TODO (`config[:resolve_recipient]`,
  # mirrors the samen_postmark/samen_ses/Smtp/Api skeleton precedent): nothing
  # in this package can know how a given host resolves a `to_subscriber_id`
  # token to a plaintext email, so today deliver/2 is honestly
  # `{:error, :not_implemented}` in real (non-fixture) use until a host wires
  # that function.
  # `verify_and_parse_event/3` needs no such host glue and is fully
  # implemented: real Svix-style webhook signature verification
  # (`SamenResend.SvixSignature` — svix-id/svix-timestamp/svix-signature
  # headers, HMAC-SHA256 over `{id}.{timestamp}.{body}`, base64 `whsec_`
  # secret) with timestamp-tolerance replay protection.
  def project do
    [
      app: :samen_resend,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # test/fixtures/conformance.exs is data loaded via Code.eval_file by the
      # shared harness, not an ExUnit test file — ignore it the same way
      # samen_postmark's/samen_ses's own test/fixtures/ carve-out does
      # (Elixir 1.20 otherwise warns about any test/ file matching neither
      # :test_load_filters nor :test_ignore_filters, and --warnings-as-errors
      # treats that as a failure).
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      # House HTTP client for adapter packages (ADR-038 §8.2), pinned per the
      # ADR. No extra vendor signing dep is needed here (unlike samen_ses's
      # AWS SigV4/aws_signature) — HMAC-SHA256 for the Svix scheme is served
      # natively by Erlang/OTP's built-in :crypto module.
      {:req, "~> 0.5"}
    ]
  end
end
