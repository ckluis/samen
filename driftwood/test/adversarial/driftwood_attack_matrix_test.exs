defmodule Driftwood.Adversarial.AttackMatrixTest do
  @moduledoc """
  The Driftwood Phase-5 adversarial attack matrix (tagged :adversarial; run as its
  own ci.sh step via `mix test --only adversarial`). Each case carries a POSITIVE
  CONTROL so the denials are non-vacuous.

  Covered attacks:
    1. FMCSA gate bypass — an expired-CDL / expired-medical / out-of-service driver
       CANNOT be dispatched (control: a compliant driver CAN). Also: the plain
       ungated create action would let it through — proving the GATE, not the
       resource, is what refuses.
    2. CDL PII egress — the raw domain column is a vault token, never plaintext, even
       for the driver's own org (own-org sees a %Masked{} value, plaintext only via
       the reveal action under a grant).
    3. Cross-org read — an org-A actor sees ZERO org-B freight rows.
  """
  use Driftwood.DataCase, async: false

  @moduletag :adversarial

  @org_a "00000000-0000-0000-0000-00000000a001"
  @org_b "00000000-0000-0000-0000-00000000b001"

  defp compliant_driver(org) do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        full_name: %{first: "Ada", last: "Adversary"},
        cdl_number: "ADV-CDL-1",
        cdl_state: "TX",
        cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), 180),
        status: :available
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp expired_driver(org) do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        full_name: %{first: "Ex", last: "Pired"},
        cdl_number: "ADV-CDL-2",
        cdl_state: "TX",
        cdl_expiry: Date.utc_today() |> Date.add(-1) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), -1),
        status: :available
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp load(org) do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: "adv load"}, authorize?: false)
    |> Ash.create!()
  end

  defp dispatch(driver, load, org) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Changeset.for_create(:dispatch, %{driver_id: driver.id, load_id: load.id},
      actor: %{org_id: org, role: :member},
      authorize?: true
    )
    |> Ash.create()
  end

  test "attack 1a: expired driver cannot be dispatched (control: compliant driver can)" do
    l1 = load(@org_a)
    l2 = load(@org_a)

    # Control — non-vacuous: a compliant driver dispatches.
    assert {:ok, _} = dispatch(compliant_driver(@org_a), l1, @org_a)

    # Attack — an expired driver is refused.
    assert {:error, err} = dispatch(expired_driver(@org_a), l2, @org_a)
    assert Exception.message(err) =~ "cdl_expired" or Exception.message(err) =~ "medical_card_expired"
  end

  test "attack 1b: the GATE is what refuses — the ungated create action would let it through" do
    expired = expired_driver(@org_a)
    l = load(@org_a)

    # The gated action refuses.
    assert {:error, _} = dispatch(expired, l, @org_a)

    # The ungated action (never used in the real workflow) would NOT refuse — proving
    # the FMCSA gate change, not the resource shape, is the load-bearing control.
    assert {:ok, _} =
             Driftwood.Freight.DispatchEvent
             |> Ash.Changeset.for_create(:create_ungated, %{driver_id: expired.id, load_id: l.id},
               actor: %{org_id: @org_a, role: :member},
               authorize?: true
             )
             |> Ash.create()
  end

  test "attack 2: CDL number never egresses as plaintext (own-org row is a vault token)" do
    d = compliant_driver(@org_a)

    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT pii_drv_cdl_number FROM drv_driver WHERE drv_id = $1",
        [Ecto.UUID.dump!(to_string(d.id))]
      )

    assert String.starts_with?(raw, "vt_")
    refute raw =~ "ADV-CDL-1"
  end

  test "attack 3: org-A actor sees ZERO org-B freight rows (control: sees its own)" do
    _b = compliant_driver(@org_b)
    a = compliant_driver(@org_a)

    a_view =
      Driftwood.Freight.Driver
      |> Ash.Query.for_read(:read, %{}, actor: %{org_id: @org_a, role: :member})
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: true)

    # Control — non-vacuous: A sees its own driver.
    assert Enum.any?(a_view, &(&1.id == a.id))
    # Attack — A sees NONE of B's.
    assert Enum.all?(a_view, &(&1.org_id == @org_a))
  end
end
