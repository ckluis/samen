defmodule S04CatalogTx.Crm do
  @moduledoc "Spike domain."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(S04CatalogTx.Crm.Contact)
  end
end
