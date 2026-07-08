defmodule Samen.WebTest.Crm do
  @moduledoc """
  The samen_web test-support CRM domain — mounts the samen_core CRM scope blueprint
  (ADR-004) exactly as driftwood/demo do, giving `samen_web` its OWN materialized CRM
  resources to render against in test. Fresh `sw*` abbrevs (the global registry already owns
  the scope-default + driftwood/demo abbrevs; append-only rows for the test host — no
  samen_core code change, ADR-009 §6).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Crm,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Crm,
    abbrevs: %{
      company: "swc",
      person: "swp",
      pipeline: "swi",
      opportunity: "swo",
      activity: "swa",
      attachment: "swt"
    }
end
