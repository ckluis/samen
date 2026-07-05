defmodule S02Transformer.Crm do
  @moduledoc "Spike domain."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(S02Transformer.Crm.Contact)
    resource(S02Transformer.Crm.Company)
  end
end
