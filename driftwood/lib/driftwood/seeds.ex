defmodule Driftwood.Seeds do
  @moduledoc """
  Tier-0 seeds for Driftwood (design §1(e), §6):

    * **Load-lifecycle stages** — Pipeline config rows (Quoted → Booked → Dispatched →
      In-Transit → Delivered → Invoiced). Tier-0: a broker reorders/renames stages
      without a fork.
    * **ELD providers** — the bounded `drv_eld_provider` enum
      (samsara/motive/geotab/other). Tier-0 config: enumerated here for the seed
      catalog and the UI dropdown; the CONSTRAINT is on the resource attribute.
    * **Load statuses** — the bounded `fop_status` set (open/won/lost/on_hold) reused
      from the kernel Opportunity; the freight-facing lifecycle lives on the Pipeline.

  `Driftwood.NonPiiSetup.register_all/0` is also called here so a fresh seed run has
  the reviewed non_pii! rows the pii_classify gate requires.
  """

  @load_stages [
    %{name: "quoted", label: "Quoted", stage_order: 0, stage_type: "open"},
    %{name: "booked", label: "Booked", stage_order: 1, stage_type: "qualified"},
    %{name: "dispatched", label: "Dispatched", stage_order: 2, stage_type: "proposal"},
    %{name: "in_transit", label: "In Transit", stage_order: 3, stage_type: "proposal"},
    %{name: "delivered", label: "Delivered", stage_order: 4, stage_type: "won"},
    %{name: "invoiced", label: "Invoiced", stage_order: 5, stage_type: "won"}
  ]

  @eld_providers [:samsara, :motive, :geotab, :other]

  @doc "The Tier-0 ELD provider catalog (the bounded drv_eld_provider enum)."
  def eld_providers, do: @eld_providers

  @doc "The Tier-0 load-lifecycle stage catalog."
  def load_stages, do: @load_stages

  @doc """
  Seed the Tier-0 rows for `org_id`. Registers the non_pii! rows first, then seeds
  the load-lifecycle Pipeline stages. Returns `:ok`.
  """
  def run(org_id) do
    :ok = Driftwood.NonPiiSetup.register_all()

    actor = %{org_id: org_id, role: :admin}

    Enum.each(@load_stages, fn stage ->
      Driftwood.Crm.Pipeline
      |> Ash.Changeset.for_create(:create, Map.put(stage, :org_id, org_id),
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()
    end)

    :ok
  end
end
