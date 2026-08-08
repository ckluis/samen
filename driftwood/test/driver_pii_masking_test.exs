defmodule Driftwood.DriverPiiMaskingTest do
  @moduledoc """
  T158 — the masking watch-list discipline (CLAUDE.md "Per-plane masking tests") for
  the vault-routed fields (`full_name`, `cdl_number`) the NEW driver create/edit
  surfaces render: the edit modal pre-fills from `Driftwood.Reads.get_driver/2`,
  which resolves through the SAME `Samen.Api.PiiResolution` seam `driver_roster/1`
  already uses — the exact seam these proofs exercise directly (not re-derived).

  `DriftwoodWeb.BrokerLive.broker_scope/1` is hardcoded `plane: :tenant` (the console
  is TENANT-only — the operator plane is a SEPARATE LiveView,
  `DriftwoodWeb.OperatorImpersonationLive`, already covered by
  `test/web_red_paths_test.exs`'s F2 describe block). So the operator-plane proof here
  is at the RESOLVER level (`resolve_on_plane/4`) — proving the seam the edit form's
  data comes from masks correctly on that plane, independent of which LiveView calls
  it, rather than rendering `BrokerLive` on a plane it structurally never mounts.

  Three proofs (masking watch-list discipline):
    1. GREEN — tenant plane resolves CLEAR (the edit-form pre-fill source).
    2. RED — operator-without-grant plane resolves `%Masked{}`, never plaintext,
       never a `vt_*` token.
    3. SABOTAGE twin (anti-tautology) — the same record flipped to tenant plane
       goes clear, and a fed "leaked" render is caught by the same scan.
  """
  use Driftwood.DataCase, async: false
  use Samen.MaskingCase
  require Ash.Query

  @org "c1230000-0000-4000-8000-0000000000a9"
  @plaintext_cdl "CDL-MC-77001"

  defp create_driver do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        full_name: %{first: "Priya", last: "Trucker"},
        cdl_number: @plaintext_cdl,
        cdl_state: "TX",
        cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), 180),
        status: :available
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # A raw (un-resolved) read — the %Masked{}-by-default record the resolver runs on,
  # exactly what `Reads.get_driver/2` selects before resolving.
  defp raw_record(driver_id) do
    Driftwood.Freight.Driver
    |> Ash.Query.filter(id == ^driver_id)
    |> Ash.Query.ensure_selected([:full_name, :cdl_number])
    |> Ash.read_one!(authorize?: false)
  end

  test "GREEN: tenant plane resolves full_name + cdl_number CLEAR (the edit-form pre-fill source)" do
    driver = create_driver()
    raw = raw_record(driver.id)

    resolved = resolve_on_plane(raw, Driftwood.Freight.Driver, :tenant, repo: Driftwood.Repo)

    assert_plane_clear!(resolved.cdl_number, @plaintext_cdl)
    # full_name resolves to the composite's JSON-ish form on the tenant plane — not masked.
    refute match?(%Samen.Masked{}, resolved.full_name)
  end

  test "RED: operator-without-grant plane resolves full_name + cdl_number MASKED — never plaintext, never a vt_ token" do
    driver = create_driver()
    raw = raw_record(driver.id)

    resolved = resolve_on_plane(raw, Driftwood.Freight.Driver, :operator, repo: Driftwood.Repo)

    assert_plane_masked!(resolved.cdl_number, @plaintext_cdl)
    assert match?(%Samen.Masked{}, resolved.full_name)
    refute to_string(resolved.full_name) =~ "vt_"
    refute to_string(resolved.full_name) =~ "Priya"
  end

  test "BOTH directions on the SAME record — tenant clear vs operator masked (anti-tautology)" do
    driver = create_driver()

    tenant = resolve_on_plane(raw_record(driver.id), Driftwood.Freight.Driver, :tenant, repo: Driftwood.Repo)
    operator = resolve_on_plane(raw_record(driver.id), Driftwood.Freight.Driver, :operator, repo: Driftwood.Repo)

    assert_two_plane!(tenant.cdl_number, operator.cdl_number, @plaintext_cdl)
  end

  test "ANTI-TAUTOLOGY: the operator mask scan is REFUTABLE — a clear render leaks and is caught" do
    driver = create_driver()

    # AS-DESIGNED: operator plane masks (the refute in the RED test above).
    operator = resolve_on_plane(raw_record(driver.id), Driftwood.Freight.Driver, :operator, repo: Driftwood.Repo)
    refute to_string(operator.cdl_number) == @plaintext_cdl

    # SABOTAGE MODEL: what a broken resolver's "operator" render would look like is
    # exactly the tenant-plane render — feed that into the leak scan and confirm it's
    # caught (proving the `refute` above is refutable, not vacuously true).
    leaked = resolve_on_plane(raw_record(driver.id), Driftwood.Freight.Driver, :tenant, repo: Driftwood.Repo)
    assert_leak_detected!(to_string(leaked.cdl_number), @plaintext_cdl)
  end

  test "the domain row never stores CDL plaintext — only a vt_ token (at-rest control)" do
    driver = create_driver()

    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT pii_drv_cdl_number FROM drv_driver WHERE drv_id = $1",
        [Ecto.UUID.dump!(to_string(driver.id))]
      )

    assert String.starts_with?(raw, "vt_")
    refute raw =~ @plaintext_cdl
  end
end
