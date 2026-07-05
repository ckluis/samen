defmodule S03Fragments.Clinical do
  @moduledoc "Spike domain composing two resources over one shared fragment."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Clinical.Patient)
    resource(Clinical.Staff)
  end
end
