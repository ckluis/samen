defmodule Samen.WebTest.Billing do
  @moduledoc """
  The samen_web test-support Billing domain — mounts the samen_core Billing scope blueprint
  (ADR-004). Fresh `wb*` abbrevs (append-only registry rows for the test host).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Billing,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Billing,
    abbrevs: %{
      customer: "wbc",
      subscription: "wbs",
      plan: "wbp",
      price: "wbr",
      invoice: "wbi",
      payment: "wby",
      usage: "wbu",
      entitlement: "wbe"
    }
end
