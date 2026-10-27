defmodule SamenCore.Support.SignalsFixture.CleanSignals do
  @moduledoc """
  Issue #96 D2 positive control: every argument is a bounded non-PII type, an array of
  ids included. `mix samen.verify.signals_no_pii` must pass a domain emitting it.
  """
  use Ash.Signals

  signals do
    signal :thing_archived do
      argument :thing_id, :uuid, allow_nil?: false
      argument :org_id, :uuid, allow_nil?: false
      argument :child_ids, {:array, :uuid}
      argument :cascade?, :boolean
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.LeakySignals do
  @moduledoc "Issue #96 D2 red path, rule (1): a PII-typed argument and a free string."
  use Ash.Signals

  signals do
    signal :contact_changed do
      argument :contact_id, :uuid, allow_nil?: false
      argument :email, Samen.Type.EmailAddress
      argument :note, :string
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.TaxSignals do
  @moduledoc """
  Issue #96 D2 red path, rule (2): every argument type is non-PII, so rule (1) passes it.
  The leak is in the emit that fills `tax_id` from a vault-routed attribute.
  """
  use Ash.Signals

  signals do
    signal :tax_id_recorded do
      argument :record_id, :uuid, allow_nil?: false
      argument :tax_id, :integer
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.Thing do
  @moduledoc "Emits only `CleanSignals` (positive control)."
  use Ash.Resource,
    domain: SamenCore.Support.SignalsFixture.CleanDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :org_id, :uuid, public?: true
  end

  actions do
    defaults [:read]

    destroy :archive do
      emit SamenCore.Support.SignalsFixture.CleanSignals, :thing_archived,
        fields: [thing_id: :id],
        values: [cascade?: true]
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.Contact do
  @moduledoc "Emits `LeakySignals` (rule 1)."
  use Ash.Resource,
    domain: SamenCore.Support.SignalsFixture.LeakyDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    update :touch do
      emit SamenCore.Support.SignalsFixture.LeakySignals, :contact_changed,
        fields: [contact_id: :id]
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.Taxpayer do
  @moduledoc "Emits `TaxSignals`, taking `tax_id` by name from a `pii_attribute` (rule 2)."
  use Ash.Resource,
    domain: SamenCore.Support.SignalsFixture.LeakyDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Samen.Extension, Samen.Pii]

  # Vault fields are `select_by_default: false`, which ETS cannot express. Only compile-time
  # introspection reads this resource; no table or migration exists for it.
  postgres do
    table "sgt_taxpayer"
    repo SamenCore.TestRepo
  end

  samen do
    abbrev("sgt")
  end

  attributes do
    uuid_primary_key :id
  end

  pii do
    vault(:pii_tax)
    pii_attribute(:tax_id, :integer, vault: :pii_tax)
  end

  actions do
    defaults [:read]

    update :record do
      # Samen.Vault.Change and Samen.Pii.WriteGuard (attached for the pii block) are not
      # atomic, and Ash warns, which fails a --warnings-as-errors compile.
      require_atomic? false

      emit SamenCore.Support.SignalsFixture.TaxSignals, :tax_id_recorded, fields: [record_id: :id]
    end
  end
end

defmodule SamenCore.Support.SignalsFixture.CleanDomain do
  @moduledoc "Issue #96 D2 fixture domain — clean. NOT in `:ash_domains`."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SamenCore.Support.SignalsFixture.Thing
  end
end

defmodule SamenCore.Support.SignalsFixture.LeakyDomain do
  @moduledoc "Issue #96 D2 fixture domain — one violation of each rule. NOT in `:ash_domains`."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SamenCore.Support.SignalsFixture.Contact
    resource SamenCore.Support.SignalsFixture.Taxpayer
  end
end
