defmodule SamenPostmark.ConformanceTest do
  @moduledoc """
  Runs the SHARED `Samen.Delivery.ProviderConformanceCase` (samen_core,
  ADR-038 §4.5) against `SamenPostmark.Provider` — cited UNCHANGED, per the
  ADR-038 roadmap-collision rule (T94/T95 do the same for their adapters).
  """
  use Samen.Delivery.ProviderConformanceCase,
    provider: SamenPostmark.Provider,
    fixtures: "test/fixtures",
    capabilities: [:deliverability_webhooks, :inbound, :tracking]
end
