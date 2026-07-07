defmodule Driftwood.CrossOrgTest do
  @moduledoc """
  RED-PATH test: cross-org isolation on the freight resources. An actor scoped to
  org A cannot read org B's Load / Carrier / Driver / Settlement — the kernel
  `OrgScope` policy (which rides underneath the Carrier/Load aliases unchanged) makes
  foreign-org rows NOT EXIST for the actor. Also proves the same-org-FK guard refuses
  a cross-org dispatch.
  """
  use Driftwood.DataCase, async: false
  require Ash.Query

  @org_a "00000000-0000-0000-0000-00000000000a"
  @org_b "00000000-0000-0000-0000-00000000000b"

  defp scope(org), do: %{org_id: org, role: :member}

  defp carrier(org, name) do
    Driftwood.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: name}, actor: scope(org))
    |> Ash.create!()
  end

  defp loadrow(org, name) do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: name}, actor: scope(org))
    |> Ash.create!()
  end

  test "actor in org A cannot READ org B's Carrier (kernel OrgScope under the alias)" do
    _b_carrier = carrier(@org_b, "Bravo Freight (org B)")

    # Org A actor lists carriers — sees ZERO of org B's rows.
    a_view =
      Driftwood.Crm.Company
      |> Ash.Query.for_read(:read, %{}, actor: scope(@org_a))
      |> Ash.read!(authorize?: true)

    assert Enum.all?(a_view, &(&1.org_id == @org_a))
    refute Enum.any?(a_view, &(&1.name == "Bravo Freight (org B)"))
  end

  test "actor in org A cannot READ org B's Load" do
    _b_load = loadrow(@org_b, "Org-B secret load")

    a_view =
      Driftwood.Crm.Opportunity
      |> Ash.Query.for_read(:read, %{}, actor: scope(@org_a))
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: true)

    refute Enum.any?(a_view, &(&1.name == "Org-B secret load"))
    assert Enum.all?(a_view, &(&1.org_id == @org_a))
  end

  test "the same-org-FK guard REFUSES a dispatch joining an org-A driver to an org-B load" do
    # An org-A driver, a compliant one.
    driver =
      Driftwood.Freight.Driver
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org_a,
          full_name: %{first: "Cross", last: "Org"},
          cdl_number: "X1",
          cdl_state: "TX",
          cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
          medical_card_expiry: Date.add(Date.utc_today(), 180),
          status: :available
        },
        authorize?: false
      )
      |> Ash.create!()

    b_load = loadrow(@org_b, "Org-B load")

    # Dispatch under org A's scope, pointing at org B's load → same-org-FK refuses.
    result =
      Driftwood.Freight.DispatchEvent
      |> Ash.Changeset.for_create(:dispatch, %{driver_id: driver.id, load_id: b_load.id},
        actor: scope(@org_a),
        authorize?: true
      )
      |> Ash.create()

    assert {:error, _err} = result

    # No dispatch row for that load.
    count =
      Driftwood.Freight.DispatchEvent
      |> Ash.Query.filter(load_id == ^b_load.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert count == 0
  end
end
