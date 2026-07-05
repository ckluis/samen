defmodule S06Verify.Crm do
  @moduledoc "Spike CRM domain for the S0.6 verifier test fixtures."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(S06Verify.Crm.Contact)
  end
end
