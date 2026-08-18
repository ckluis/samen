defmodule SamenResend.ConformanceTest do
  @moduledoc """
  Runs the SHARED `Samen.Delivery.ProviderConformanceCase` (samen_core,
  ADR-038 §4.5) against `SamenResend.Provider` — cited UNCHANGED, per the
  ADR-038 roadmap-collision rule (the same harness `samen_postmark`/T27 and
  `samen_ses`/T94 run).

  No `:inbound` capability (ADR-038 §4.5 adapter split: "samen_resend ... no
  inbound") — the harness's capability-honesty assertion (§4.5e) therefore
  proves `parse_inbound/3` ALWAYS refuses `{:error, :not_implemented}`, even
  when configured.
  """
  use Samen.Delivery.ProviderConformanceCase,
    provider: SamenResend.Provider,
    fixtures: "test/fixtures",
    capabilities: [:deliverability_webhooks, :tracking]
end
