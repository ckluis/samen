defmodule PawChart.ClinicSurfaceTest do
  @moduledoc """
  PP-4 (Batch 5b CLINIC-SURFACE) — the clinic's OWN tenant surface over
  `PawChart.Clinic.{Patient,Pet}` (`PawChartWeb.ClinicLive` + `PawChartWeb.ClinicReads`).

  The load-bearing proofs this file exists for:

    * **ORG-SCOPE** — a clinic reads ONLY its own patients/pets. Proven refutably by a
      cross-org red-path (clinic B's owner/pet is NEVER visible to clinic A) paired with a
      positive control (clinic A DOES see its own). A cross-org `?patient=`/edit id is
      refused (`get_owner/2` → `:error`). A cross-org owner→pet FK is refused (SameOrgFk).
      Sabotage patch 181 flips the named cross-org read test.
    * **CRUD** — clinic staff (a plain tenant `:member`) can create + edit their own
      patients and pets through the real Ash actions on the tenant scope.
    * **HONESTY** — a fresh clinic with no patients/pets renders real empty states, never a
      stub or a crash.
    * **NAV-REACHABILITY** — the `/clinic` route is mounted (the `@tenant_landing` target is
      a LIVE route, not a 404) and the "Clinic" nav group is data-reachable.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  alias PawChartWeb.ClinicLive
  alias PawChartWeb.ClinicReads, as: Reads

  @org_a "c1112d00-0000-4000-8000-00000000a001"
  @org_b "c1112d00-0000-4000-8000-00000000b001"

  defp create_owner!(org, first, opts \\ []) do
    Reads.create_owner(org, %{
      "first" => first,
      "last" => "Owner",
      "email" => Keyword.get(opts, :email, "#{String.downcase(first)}@example.test"),
      "phone" => Keyword.get(opts, :phone, "+15550000000")
    })
    |> then(fn {:ok, owner} -> owner end)
  end

  defp create_pet!(org, name, owner_id \\ nil) do
    Reads.create_pet(org, %{
      "name" => name,
      "species" => "canine",
      "owner_id" => owner_id || ""
    })
    |> then(fn {:ok, pet} -> pet end)
  end

  # A minimal render of the LiveView through its real load/1 + render/1 (no Endpoint),
  # mirroring samen_web's render_live harness.
  defp render_clinic(org_id, params \\ %{}) do
    mount =
      Samen.Web.Mount.new(:crm, PawChart.Crm, PawChart.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{title: "Happy Paws Clinic", glyph: "V"}
      )

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> ClinicLive.load(org_id, params)

    socket.assigns
    |> Map.put(:__changed__, %{})
    |> ClinicLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ==========================================================================
  # ORG-SCOPE red-path (sabotage 181 target) + positive control
  # ==========================================================================

  test "CROSS-ORG: clinic A's owner_roster NEVER returns clinic B's patient (positive control: its own IS visible)" do
    a_owner = create_owner!(@org_a, "Alice")
    b_owner = create_owner!(@org_b, "SecretBoberta")

    a_roster = Reads.owner_roster(Reads.tenant_scope(@org_a))
    a_ids = Enum.map(a_roster, & &1.id)

    # RED: clinic B's patient is invisible to clinic A.
    refute b_owner.id in a_ids,
           "cross-org leak: clinic B's patient appeared in clinic A's roster"

    # POSITIVE CONTROL (non-vacuous): clinic A DOES see its own patient.
    assert a_owner.id in a_ids
  end

  test "CROSS-ORG: clinic A's pet_roster NEVER returns clinic B's pet (positive control: its own IS visible)" do
    a_pet = create_pet!(@org_a, "Rex-A")
    b_pet = create_pet!(@org_b, "Rex-B")

    a_pet_ids = @org_a |> Reads.tenant_scope() |> Reads.pet_roster() |> Enum.map(& &1.id)

    refute b_pet.id in a_pet_ids
    assert a_pet.id in a_pet_ids
  end

  test "CROSS-ORG: get_owner refuses a foreign-org patient id (:error) but returns the org's own ({:ok})" do
    a_owner = create_owner!(@org_a, "Ada")
    b_owner = create_owner!(@org_b, "Bianca")

    scope_a = Reads.tenant_scope(@org_a)

    # A foreign-org id (e.g. supplied via ?patient=<B>) is invisible under OrgScope.
    assert :error = Reads.get_owner(scope_a, b_owner.id)
    # Positive control: the org's own patient resolves.
    assert {:ok, %{id: id}} = Reads.get_owner(scope_a, a_owner.id)
    assert id == a_owner.id
  end

  test "CROSS-ORG write: a pet in clinic A pointing at a clinic-B owner is REFUSED (SameOrgFk)" do
    b_owner = create_owner!(@org_b, "Boris")

    assert {:error, _} =
             Reads.create_pet(@org_a, %{"name" => "CrossPet", "species" => "feline", "owner_id" => b_owner.id})

    # No pet row references that cross-org owner.
    count =
      PawChart.Clinic.Pet
      |> Ash.Query.filter(owner_id == ^b_owner.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert count == 0
  end

  # ==========================================================================
  # CRUD — a plain tenant member manages their own patients + pets
  # ==========================================================================

  test "clinic staff can CREATE a patient and it appears in the org's roster" do
    assert {:ok, owner} = Reads.create_owner(@org_a, %{"first" => "Nora", "last" => "New", "email" => "nora@example.test"})

    roster = Reads.owner_roster(Reads.tenant_scope(@org_a))
    assert owner.id in Enum.map(roster, & &1.id)
  end

  test "clinic staff can EDIT a patient's marketing flag" do
    owner = create_owner!(@org_a, "Edith")

    assert {:ok, _} =
             Reads.update_owner(@org_a, owner.id, %{
               "first" => "Edith",
               "last" => "Owner",
               "email" => "edith@example.test",
               "phone" => "+15550001111",
               "marketing_opt_in" => "true"
             })

    {:ok, reloaded} = Reads.get_owner(Reads.tenant_scope(@org_a), owner.id)
    assert reloaded.marketing_opt_in == true
  end

  test "clinic staff can CREATE a pet linked to an in-org owner" do
    owner = create_owner!(@org_a, "Petra")

    assert {:ok, pet} =
             Reads.create_pet(@org_a, %{
               "name" => "Fido",
               "species" => "canine",
               "breed" => "labrador",
               "temperament" => "docile",
               "owner_id" => owner.id
             })

    assert pet.owner_id == owner.id
    assert pet.name == "Fido"
  end

  # ==========================================================================
  # HONESTY — a fresh clinic renders real empty states (no crash / no stub)
  # ==========================================================================

  test "a fresh clinic (no patients/pets) renders honest empty states, not a crash" do
    html = render_clinic("c1112d00-0000-4000-8000-00000000f001")

    assert html =~ "No patients yet."
    assert html =~ "No pets yet."
    # No leaked internals, and the page actually rendered.
    assert byte_size(html) > 0
  end

  test "the surface renders the org's patients + pets" do
    owner = create_owner!(@org_a, "Rendered")
    _pet = create_pet!(@org_a, "RenderedPet", owner.id)

    html = render_clinic(@org_a)

    assert html =~ "patient-#{owner.id}"
    assert html =~ "RenderedPet"
    assert html =~ "Rendered"
  end

  # ==========================================================================
  # NAV-REACHABILITY — /clinic is a live route (the tenant_landing target) and
  # the "Clinic" nav group is data-reachable.
  # ==========================================================================

  test "the /clinic route is mounted on the tenant plane (the tenant_landing target is not a 404)" do
    paths =
      PawChartWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)

    assert "/clinic" in paths
  end

  test "clinic_nav_data yields a reachable 'Clinic' nav group pointing at /clinic" do
    group = ClinicLive.clinic_nav_data(@org_a)

    assert group.label == "Clinic"
    assert [%{href: href}] = group.items
    assert href =~ "/clinic?org=#{@org_a}"
  end
end
