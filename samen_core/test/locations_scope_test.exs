defmodule Samen.LocationsScopeTest do
  @moduledoc """
  The Locations scope (F5, T47) — Location on `Samen.Type.Address` (c17 split:
  ADR-036/T14 shipped the composite type + `pii_address` recipe, this scope is the
  resource that uses it), mounted via `test/support/locations_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, org-less fail-closed — mirrors `Samen.DocsScopeTest`/`Samen.TagsScopeTest`
      c1);
    * c2 archive/restore (ADR-040 §5.9): hide-on-archive / show-via-`:archived` /
      return-on-restore, double-archive idempotent;
    * c3 no geometry column (ADR-037 §5.10 — `ash_geo` REJECT, T47 explicitly
      named): `address` is the ONLY location-shaped attribute, no lat/lng/geometry
      column, own table (never shared with any other scope);
    * c4 INV-1 — `address` masks by default (green/red/sabotage three-proof,
      `Samen.MaskingCase`): tenant plane clear, operator-without-grant plane
      `%Samen.Masked{}` (never plaintext, never a `vt_*` token), leak scan
      refutable (anti-tautology) — the SAME recipe `Samen.Type.AddressTest` proved
      generically, applied to this real resource;
    * c5 vault routing: `address` lands a `vt_*` token in the raw domain row,
      plaintext nowhere, ciphertext in `pii_vault`;
    * c6 an ARCHIVED Location keeps its vault token and still masks per plane;
    * c7 catalog registration — `mix samen.verify.catalog_parity` is green.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Archival
  alias SamenCore.Support.LocationsFixture.Location

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane
  # must mask. Proves the mask is the plane/grant gate, independent of decrypt
  # availability (mirrors Samen.DocsScopeTest/Samen.TagsScopeTest's DenyAll).
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  @address %{line1: "1600 Amphitheatre Pkwy", city: "Mountain View", region: "CA", country: "us"}

  defp new_location(scope, org, attrs \\ %{}) do
    Location
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, name: "Warehouse"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  # address is NOT select-by-default — a fresh read that needs it must select
  # it explicitly (mirrors every other 🔒 field, e.g.
  # Samen.CalendarScopeTest.with_attendees_loaded/2).
  defp with_address_loaded(%{id: id}, scope) do
    Location
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:address])
    |> Ash.read_one!(scope: scope)
  end

  defp location_ids(scope), do: Location |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_locations(scope),
    do: Location |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  # ── c1: CRUD via governed actions; org-scoped reads ───────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Location", %{org: org, scope: scope} do
      l = new_location(scope, org, %{name: "Springfield Site"})
      assert l.name == "Springfield Site"

      [read] = Location |> Ash.read!(scope: scope)
      assert read.id == l.id

      updated =
        l |> Ash.Changeset.for_update(:update, %{name: "Springfield Site v2"}, scope: scope) |> Ash.update!()

      assert updated.name == "Springfield Site v2"

      :ok = Ash.destroy!(l, scope: scope)
      assert Location |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Locations (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      loc_a = new_location(scope_a, org_a, %{name: "A"})
      _loc_b = new_location(scope_b, org_b, %{name: "B"})

      seen = Location |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert loc_a.id in seen and length(seen) == 1
    end

    test "an org-less actor sees zero Locations (fail closed)", %{org: org, scope: scope} do
      _l = new_location(scope, org, %{name: "hidden"})

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Location, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end

    test "address casts/dumps as a partial or full Samen.Type.Address value", %{org: org, scope: scope} do
      l = new_location(scope, org, %{name: "Partial", address: %{city: "Springfield", country: "us"}})
      assert l.name == "Partial"

      full = new_location(scope, org, %{name: "Full", address: @address})
      assert full.name == "Full"
    end
  end

  # ── c2: archive/restore ────────────────────────────────────────────────────

  describe "c2 — archive/restore (ADR-040 §5.9)" do
    test "archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      l = new_location(scope, org)
      {:ok, _} = Archival.archive(l, scope: scope)

      refute MapSet.member?(location_ids(scope), l.id)
      assert Enum.any?(archived_locations(scope), &(&1.id == l.id))

      restored = archived_locations(scope) |> Enum.find(&(&1.id == l.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(location_ids(scope), l.id)
    end

    test "double-archive is an idempotent no-op (archived_at does not move)", %{org: org, scope: scope} do
      l = new_location(scope, org)
      {:ok, once} = Archival.archive(l, scope: scope)
      {:ok, twice} = Archival.archive(once, scope: scope)
      assert once.archived_at == twice.archived_at
    end
  end

  # ── c3: no geometry column (ADR-037 §5.10) ──────────────────────────────────

  describe "c3 — no geometry column (ADR-037 §5.10, ash_geo REJECT)" do
    test "address is the ONLY location-shaped attribute — no lat/lng/geometry column" do
      names = Location |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

      assert :address in names
      refute :latitude in names
      refute :longitude in names
      refute :lat in names
      refute :lng in names
      refute :geo in names
      refute :geometry in names
      refute :coordinates in names
    end

    test "the address field's TYPE is Samen.Type.Address (the H4 composite, per c17)" do
      field = Location |> Samen.Pii.Info.fields() |> Enum.find(&(&1.name == :address))

      refute is_nil(field)
      assert field.type == Samen.Type.Address
      assert field.vault == :pii_address
      assert field.composite? == true
    end

    test "own table — never shared with another scope" do
      assert AshPostgres.DataLayer.Info.table(Location) == "sll_location"
    end
  end

  # ── c4: INV-1 — address masks by default (three-proof) ────────────────────

  describe "c4 — INV-1: address masks by default (green/red/sabotage three-proof)" do
    test "GREEN: tenant plane resolves Location.address CLEAR", %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address}) |> with_address_loaded(scope)

      resolved = l |> resolve_on_plane(Location, :tenant, repo: @repo) |> Map.get(:address)

      refute match?(%Samen.Masked{}, resolved)

      decoded = Jason.decode!(resolved)
      assert decoded["city"] == "Mountain View"
      assert decoded["country"] == "US"
    end

    test "RED: operator-without-grant plane resolves Location.address to %Masked{} — never " <>
           "plaintext, never a vt_ token", %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address}) |> with_address_loaded(scope)

      masked = resolve_on_plane(l, Location, :operator, repo: @repo, grant: DenyAll).address
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ "Mountain View"
      refute to_string(masked) =~ "vt_"
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address}) |> with_address_loaded(scope)

      tenant_val = resolve_on_plane(l, Location, :tenant, repo: @repo).address
      operator_val = resolve_on_plane(l, Location, :operator, repo: @repo, grant: DenyAll).address

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught",
         %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address}) |> with_address_loaded(scope)

      leaked = "<div>address: #{Jason.encode!(@address)}</div>"
      assert_leak_detected!(leaked, "Mountain View")

      masked = resolve_on_plane(l, Location, :operator, repo: @repo, grant: DenyAll).address
      assert_plane_masked!(masked, nil)
    end
  end

  # ── c5: vault routing ───────────────────────────────────────────────────────

  describe "c5 — vault routing: address writes a vt_ token; plaintext never in the domain row" do
    test "Location raw-row + pii_vault proof", %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address})
      Samen.RedPath.assert_vault_routed!(@repo, Location, l.id, [:address], ["Mountain View"])
    end

    test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
      assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])
      assert :error == Samen.Type.VaultField.dump_to_native("Mountain View", [])
    end
  end

  # ── c6: an archived Location keeps its vault token and still masks per plane ─

  describe "c6 — archiving does not disturb INV-1 (trash, not erasure)" do
    test "archived Location: vt_ token at rest, masks on operator plane (RED), clears on " <>
           "tenant (CONTROL)", %{org: org, scope: scope} do
      l = new_location(scope, org, %{address: @address})
      {:ok, _} = Archival.archive(l, scope: scope)

      archived =
        Location
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^l.id)
        |> Ash.Query.ensure_selected([:address])
        |> Ash.read!(scope: scope)
        |> hd()

      %{rows: [[stored]]} =
        @repo.query!("SELECT sll_address FROM sll_location WHERE sll_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      masked = resolve_on_plane(archived, Location, :operator, repo: @repo, grant: DenyAll).address
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ "Mountain View"

      tenant_val = resolve_on_plane(archived, Location, :tenant, repo: @repo).address
      refute match?(%Samen.Masked{}, tenant_val)
    end
  end

  # ── c7: catalog registration ────────────────────────────────────────────────

  describe "c7 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Locations fixture's table/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "sll_location"))

      assert violations == [],
             "expected no catalog_parity violations for the Locations fixture table, got: " <>
               inspect(violations)
    end
  end
end
