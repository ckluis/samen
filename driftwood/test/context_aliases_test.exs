defmodule Driftwood.ContextAliasesTest do
  @moduledoc """
  Proves the `Driftwood.Context` bounded-context map (design §1.2, DECISIONS C/A/L):

    * Carrier AND Shipper both alias the ONE kernel Company (DECISION C2 — two
      name-only renames over one resource, not two resources);
    * Load aliases Opportunity (DECISION L); CheckCall aliases Activity (DECISION A);
    * an aliased read runs against the KERNEL resource, so the kernel OrgScope policy
      still filters — the alias re-names, it cannot re-authorize or widen (the
      anti-corruption invariant).
    * the reshape derived fields (Settlement netting) are catalogued as
      context-derived fields (physical?: false) for LLM grounding — NOT physical
      columns (a reshape mints no storage).
  """
  use Driftwood.DataCase, async: false

  test "Carrier and Shipper both alias the ONE kernel Company (DECISION C2)" do
    assert Samen.Context.kernel_resource(Driftwood.Context, Driftwood.Carrier) ==
             Driftwood.Crm.Company

    assert Samen.Context.kernel_resource(Driftwood.Context, Driftwood.Shipper) ==
             Driftwood.Crm.Company

    aliases = Samen.Context.Info.aliases(Driftwood.Context)
    carrier = Enum.find(aliases, &(&1.alias == Driftwood.Carrier))
    shipper = Enum.find(aliases, &(&1.alias == Driftwood.Shipper))

    assert carrier.resource == Driftwood.Crm.Company
    assert shipper.resource == Driftwood.Crm.Company
    # ONE resource, two aliases — the decisive DECISION-C2 shape.
    assert carrier.resource == shipper.resource
  end

  test "Load aliases Opportunity; CheckCall aliases Activity" do
    assert Samen.Context.kernel_resource(Driftwood.Context, Driftwood.Load) ==
             Driftwood.Crm.Opportunity

    assert Samen.Context.kernel_resource(Driftwood.Context, Driftwood.CheckCall) ==
             Driftwood.Crm.Activity
  end

  test "an aliased read runs against the kernel resource and stays org-scoped (anti-corruption)" do
    org_a = "00000000-0000-0000-0000-00000000e001"
    org_b = "00000000-0000-0000-0000-00000000e002"

    for {org, name} <- [{org_a, "A carrier"}, {org_b, "B carrier"}] do
      Driftwood.Crm.Company
      |> Ash.Changeset.for_create(:create, %{org_id: org, name: name},
        actor: %{org_id: org, role: :member}
      )
      |> Ash.create!()
    end

    # Query via the Carrier ALIAS — it builds an Ash.Query for the kernel Company,
    # so the kernel OrgScope policy filters org B's rows out for an org-A actor.
    a_view =
      Samen.Context.query(Driftwood.Context, Driftwood.Carrier)
      |> Ash.Query.for_read(:read, %{}, actor: %{org_id: org_a, role: :member})
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: true)

    assert Enum.all?(a_view, &(&1.org_id == org_a))
    refute Enum.any?(a_view, &(&1.name == "B carrier"))
  end

  test "reshape derived fields are catalogued as context-derived (not physical columns)" do
    map = Samen.Context.Info.catalog_context_map(Driftwood.Context)

    # The netting calc names appear in the context map's derived_fields keyed to the
    # Settlement kernel table, marked physical?: false — a reshape mints no fld_field.
    assert Enum.all?(map.derived_fields, &(&1.physical? == false))
    derived_names = Enum.map(map.derived_fields, & &1.context_field)

    for expected <- ~w(gross_cents factoring_fee_cents net_payable_cents carryover_cents) do
      assert expected in derived_names,
             "expected #{expected} in the context-derived-field catalog map, got: #{inspect(derived_names)}"
    end

    # And Carrier/Shipper/Load/CheckCall aliases are all catalogued for LLM grounding.
    alias_names = Enum.map(map.aliases, & &1.alias_name)
    assert "Driftwood.Carrier" in alias_names
    assert "Driftwood.Shipper" in alias_names
    assert "Driftwood.Load" in alias_names
    assert "Driftwood.CheckCall" in alias_names
  end
end
