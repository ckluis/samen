defmodule Samen.SalesOpsScopeTest do
  @moduledoc """
  The SalesOps scope (F6+F7, T48) — Vendor + Lead, mounted via
  `test/support/sales_ops_fixture.ex`, converting into the REAL `Samen.Scopes.Crm`
  blueprint mounted via `test/support/crm_scope_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (Vendor + Lead);
    * c2 archive/restore (ADR-040 §5.9) on both resources;
    * c3 Lead is a DISTINCT resource/table from Marketing `Subscriber` (done-criterion
      2's "separate tables/resources" probe, against the REAL `Samen.Scopes.Marketing`
      mount `SamenCore.Support.SuppressionFixture.Subscriber`);
    * c4 INV-1 — Vendor's `contact_name`/`contact_emails`/`contact_phones` and Lead's
      `full_name`/`emails`/`phones` mask by default (green/red/sabotage three-proof,
      `Samen.MaskingCase`);
    * c5 vault routing: every PII field lands a `vt_*` token in the raw domain row,
      plaintext nowhere, ciphertext in `pii_vault` (done-criterion 2's "PII vaulted at
      write");
    * c6 Money exactness (INV-2): `Lead.value` round-trips a fractional-cents amount
      byte-exact, Decimal-backed, never a float;
    * c7 conversion (F7, done-criterion 3): `Lead.convert` creates a host CRM
      Person (Contact) + Opportunity (carrying `value` unchanged), links + closes the
      Lead ATOMICALLY; the created Person's PII is FRESHLY vaulted (a different token
      from the Lead's own — no leak across conversion) and masks per plane exactly
      like any other vaulted field; double-convert is REFUSED (idempotence red +
      control); a mid-conversion failure (cross-org `company_id`) rolls back the
      WHOLE transaction — the Lead stays unconverted, no orphan Person/Opportunity;
    * c8 catalog registration — `mix samen.verify.catalog_parity` is green.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Archival
  alias SamenCore.Support.CrmScopeFixture
  alias SamenCore.Support.SalesOpsFixture.{Lead, Vendor}
  alias SamenCore.Support.SuppressionFixture

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane
  # must mask. Proves the mask is the plane/grant gate, independent of decrypt
  # availability (mirrors Samen.DocsScopeTest/Samen.TagsScopeTest/Samen.LocationsScopeTest).
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

  @full_name %{first: "Grace", last: "Hopper"}
  @emails %{entries: [%{label: "work", address: "grace@example.com"}]}
  @phones %{entries: [%{label: "work", number: "+15550100100"}]}

  defp new_vendor(scope, org, attrs \\ %{}) do
    Vendor
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, name: "Acme Supplies"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_lead(scope, org, attrs \\ %{}) do
    Lead
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org}, attrs), scope: scope)
    |> Ash.create!()
  end

  defp with_vendor_pii_loaded(%{id: id}, scope) do
    Vendor
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:contact_name, :contact_emails, :contact_phones])
    |> Ash.read_one!(scope: scope)
  end

  defp with_lead_pii_loaded(%{id: id}, scope) do
    Lead
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones])
    |> Ash.read_one!(scope: scope)
  end

  defp vendor_ids(scope), do: Vendor |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  defp lead_ids(scope), do: Lead |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_vendors(scope), do: Vendor |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  defp archived_leads(scope), do: Lead |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  defp convert!(lead, scope, args \\ %{}) do
    lead
    |> Ash.Changeset.for_update(:convert, args, scope: scope)
    |> Ash.update!()
  end

  defp new_company(scope, org) do
    CrmScopeFixture.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: "Foreign Co"}, scope: scope)
    |> Ash.create!()
  end

  # ── c1: CRUD via governed actions; org-scoped reads ───────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Vendor", %{org: org, scope: scope} do
      v = new_vendor(scope, org, %{name: "Springfield Supplies"})
      assert v.name == "Springfield Supplies"
      assert v.status == :active

      [read] = Vendor |> Ash.read!(scope: scope)
      assert read.id == v.id

      updated = v |> Ash.Changeset.for_update(:update, %{status: :inactive}, scope: scope) |> Ash.update!()
      assert updated.status == :inactive

      :ok = Ash.destroy!(v, scope: scope)
      assert Vendor |> Ash.read!(scope: scope) == []
    end

    test "create/read/update/destroy(=archive) a Lead", %{org: org, scope: scope} do
      l = new_lead(scope, org, %{company_name: "Springfield Nuclear"})
      assert l.company_name == "Springfield Nuclear"
      assert l.status == :new

      [read] = Lead |> Ash.read!(scope: scope)
      assert read.id == l.id

      updated = l |> Ash.Changeset.for_update(:update, %{status: :qualified}, scope: scope) |> Ash.update!()
      assert updated.status == :qualified

      :ok = Ash.destroy!(l, scope: scope)
      assert Lead |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Vendors/Leads (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      v_a = new_vendor(scope_a, org_a, %{name: "A Co"})
      _v_b = new_vendor(scope_b, org_b, %{name: "B Co"})
      l_a = new_lead(scope_a, org_a)
      _l_b = new_lead(scope_b, org_b)

      seen_v = Vendor |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)
      seen_l = Lead |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert v_a.id in seen_v and length(seen_v) == 1
      assert l_a.id in seen_l and length(seen_l) == 1
    end

    test "an org-less actor sees zero Vendors/Leads (fail closed)", %{org: org, scope: scope} do
      _v = new_vendor(scope, org)
      _l = new_lead(scope, org)

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Vendor, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end

      case Ash.read(Lead, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end
  end

  # ── c2: archive/restore ────────────────────────────────────────────────────

  describe "c2 — archive/restore (ADR-040 §5.9)" do
    test "archive hides Vendor (RED), :archived shows it (CONTROL), restore returns it", %{org: org, scope: scope} do
      v = new_vendor(scope, org)
      {:ok, _} = Archival.archive(v, scope: scope)

      refute MapSet.member?(vendor_ids(scope), v.id)
      assert Enum.any?(archived_vendors(scope), &(&1.id == v.id))

      restored = archived_vendors(scope) |> Enum.find(&(&1.id == v.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(vendor_ids(scope), v.id)
    end

    test "archive hides Lead (RED), :archived shows it (CONTROL), restore returns it", %{org: org, scope: scope} do
      l = new_lead(scope, org)
      {:ok, _} = Archival.archive(l, scope: scope)

      refute MapSet.member?(lead_ids(scope), l.id)
      assert Enum.any?(archived_leads(scope), &(&1.id == l.id))

      restored = archived_leads(scope) |> Enum.find(&(&1.id == l.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(lead_ids(scope), l.id)
    end
  end

  # ── c3: Lead is distinct from Marketing Subscriber ─────────────────────────

  describe "c3 — Lead is a distinct resource/table from Marketing Subscriber" do
    test "separate tables — never shared storage" do
      lead_table = AshPostgres.DataLayer.Info.table(Lead)
      subscriber_table = AshPostgres.DataLayer.Info.table(SuppressionFixture.Subscriber)

      assert lead_table == "sls_lead"
      assert subscriber_table == "sxs_subscriber"
      refute lead_table == subscriber_table
    end

    test "separate schema — Lead's sales shape vs Subscriber's consent shape" do
      lead_attrs = Lead |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
      subscriber_attrs = SuppressionFixture.Subscriber |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

      assert :full_name in lead_attrs
      refute :full_name in subscriber_attrs

      assert :value in lead_attrs
      refute :value in subscriber_attrs

      assert :consent_at in subscriber_attrs
      refute :consent_at in lead_attrs
    end

    test "separate actions — only Lead carries :convert" do
      lead_actions = Lead |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)
      subscriber_actions = SuppressionFixture.Subscriber |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

      assert :convert in lead_actions
      refute :convert in subscriber_actions
    end
  end

  # ── c4: INV-1 — Vendor/Lead PII masks by default (three-proof) ────────────

  describe "c4 — INV-1: Vendor contact PII masks by default" do
    test "GREEN: tenant plane resolves Vendor.contact_name/emails/phones CLEAR", %{org: org, scope: scope} do
      v =
        new_vendor(scope, org, %{contact_name: @full_name, contact_emails: @emails, contact_phones: @phones})
        |> with_vendor_pii_loaded(scope)

      resolved = resolve_on_plane(v, Vendor, :tenant, repo: @repo)

      refute match?(%Samen.Masked{}, resolved.contact_name)
      decoded_name = Jason.decode!(resolved.contact_name)
      assert decoded_name["first"] == "Grace"

      decoded_emails = Jason.decode!(resolved.contact_emails)
      assert [%{"address" => "grace@example.com"}] = decoded_emails["entries"]
    end

    test "RED: operator-without-grant plane resolves Vendor contact fields to %Masked{} — " <>
           "never plaintext, never a vt_ token",
         %{org: org, scope: scope} do
      v =
        new_vendor(scope, org, %{contact_name: @full_name, contact_emails: @emails, contact_phones: @phones})
        |> with_vendor_pii_loaded(scope)

      resolved = resolve_on_plane(v, Vendor, :operator, repo: @repo, grant: DenyAll)

      assert_plane_masked!(resolved.contact_name, nil)
      assert_plane_masked!(resolved.contact_emails, nil)
      assert_plane_masked!(resolved.contact_phones, nil)
      refute to_string(resolved.contact_name) =~ "Grace"
      refute to_string(resolved.contact_name) =~ "vt_"
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      v =
        new_vendor(scope, org, %{contact_name: @full_name})
        |> with_vendor_pii_loaded(scope)

      tenant_val = resolve_on_plane(v, Vendor, :tenant, repo: @repo).contact_name
      operator_val = resolve_on_plane(v, Vendor, :operator, repo: @repo, grant: DenyAll).contact_name

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught",
         %{org: org, scope: scope} do
      v = new_vendor(scope, org, %{contact_name: @full_name}) |> with_vendor_pii_loaded(scope)

      leaked = "<div>contact: #{Jason.encode!(@full_name)}</div>"
      assert_leak_detected!(leaked, "Grace")

      masked = resolve_on_plane(v, Vendor, :operator, repo: @repo, grant: DenyAll).contact_name
      assert_plane_masked!(masked, nil)
    end
  end

  describe "c4 — INV-1: Lead PII masks by default" do
    test "GREEN: tenant plane resolves Lead.full_name/emails/phones CLEAR", %{org: org, scope: scope} do
      l =
        new_lead(scope, org, %{full_name: @full_name, emails: @emails, phones: @phones})
        |> with_lead_pii_loaded(scope)

      resolved = resolve_on_plane(l, Lead, :tenant, repo: @repo)

      refute match?(%Samen.Masked{}, resolved.full_name)
      assert Jason.decode!(resolved.full_name)["last"] == "Hopper"
    end

    test "RED: operator-without-grant plane resolves Lead PII fields to %Masked{} — never " <>
           "plaintext, never a vt_ token",
         %{org: org, scope: scope} do
      l =
        new_lead(scope, org, %{full_name: @full_name, emails: @emails, phones: @phones})
        |> with_lead_pii_loaded(scope)

      resolved = resolve_on_plane(l, Lead, :operator, repo: @repo, grant: DenyAll)

      assert_plane_masked!(resolved.full_name, nil)
      assert_plane_masked!(resolved.emails, nil)
      assert_plane_masked!(resolved.phones, nil)
      refute to_string(resolved.full_name) =~ "Grace"
      refute to_string(resolved.full_name) =~ "vt_"
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      l = new_lead(scope, org, %{full_name: @full_name}) |> with_lead_pii_loaded(scope)

      tenant_val = resolve_on_plane(l, Lead, :tenant, repo: @repo).full_name
      operator_val = resolve_on_plane(l, Lead, :operator, repo: @repo, grant: DenyAll).full_name

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end
  end

  # ── c5: vault routing ───────────────────────────────────────────────────────

  describe "c5 — vault routing: PII writes a vt_ token; plaintext never in the domain row" do
    test "Vendor raw-row + pii_vault proof", %{org: org, scope: scope} do
      v = new_vendor(scope, org, %{contact_name: @full_name, contact_emails: @emails, contact_phones: @phones})

      Samen.RedPath.assert_vault_routed!(@repo, Vendor, v.id, [:contact_name, :contact_emails, :contact_phones], [
        "Grace",
        "grace@example.com"
      ])
    end

    test "Lead raw-row + pii_vault proof", %{org: org, scope: scope} do
      l = new_lead(scope, org, %{full_name: @full_name, emails: @emails, phones: @phones})

      Samen.RedPath.assert_vault_routed!(@repo, Lead, l.id, [:full_name, :emails, :phones], [
        "Grace",
        "grace@example.com"
      ])
    end
  end

  # ── c6: Money exactness (INV-2) ─────────────────────────────────────────────

  describe "c6 — Lead.value is Samen.Type.Money, exact (never a float)" do
    test "a fractional-cents amount round-trips byte-exact", %{org: org, scope: scope} do
      l = new_lead(scope, org, %{value: Money.new!(:USD, "1234.56")})

      [read] = Lead |> Ash.Query.filter(id == ^l.id) |> Ash.read!(scope: scope)

      assert %Money{} = read.value
      assert Money.equal?(read.value, Money.new!(:USD, "1234.56"))
      assert Samen.Type.Money.cents(read.value) == 123_456
      refute is_float(read.value.amount)
    end

    test "the field's declared type is Samen.Type.Money" do
      field = Lead |> Ash.Resource.Info.attribute(:value)
      assert field.type == Samen.Type.Money
    end
  end

  # ── c7: F7 conversion ────────────────────────────────────────────────────────

  describe "c7 — Lead.convert creates a Contact + Opportunity and closes the Lead atomically" do
    test "convert creates a CRM Person (Contact) + Opportunity carrying value, links + closes " <>
           "the Lead",
         %{org: org, scope: scope} do
      l =
        new_lead(scope, org, %{
          full_name: @full_name,
          emails: @emails,
          phones: @phones,
          company_name: "Hopper Compilers",
          value: Money.new!(:USD, "5000.00")
        })

      converted = convert!(l, scope)

      assert converted.status == :converted
      refute is_nil(converted.converted_at)
      refute is_nil(converted.converted_person_id)
      refute is_nil(converted.converted_opportunity_id)

      person = Ash.get!(CrmScopeFixture.Person, converted.converted_person_id, scope: scope)
      opportunity = Ash.get!(CrmScopeFixture.Opportunity, converted.converted_opportunity_id, scope: scope)

      assert Money.equal?(opportunity.value, Money.new!(:USD, "5000.00"))

      person_with_pii =
        CrmScopeFixture.Person
        |> Ash.Query.filter(id == ^person.id)
        |> Ash.Query.ensure_selected([:full_name, :emails, :phones])
        |> Ash.read_one!(scope: scope)

      resolved_person = resolve_on_plane(person_with_pii, CrmScopeFixture.Person, :tenant, repo: @repo)
      decoded_name = Jason.decode!(resolved_person.full_name)
      assert decoded_name["first"] == "Grace"
      assert decoded_name["last"] == "Hopper"

      decoded_emails = Jason.decode!(resolved_person.emails)
      assert [%{"address" => "grace@example.com"}] = decoded_emails["entries"]
    end

    test "the converted Person's PII is FRESHLY vaulted — a DIFFERENT token from the Lead's own " <>
           "(no shared token, no leak across conversion)",
         %{org: org, scope: scope} do
      l = new_lead(scope, org, %{full_name: @full_name, emails: @emails, phones: @phones})

      %{rows: [[lead_token]]} =
        @repo.query!("SELECT sls_full_name FROM sls_lead WHERE sls_id = $1", [Ecto.UUID.dump!(l.id)])

      converted = convert!(l, scope)

      %{rows: [[person_token]]} =
        @repo.query!("SELECT scp_full_name FROM scp_person WHERE scp_id = $1", [
          Ecto.UUID.dump!(converted.converted_person_id)
        ])

      assert is_binary(lead_token) and String.starts_with?(lead_token, "vt_")
      assert is_binary(person_token) and String.starts_with?(person_token, "vt_")
      refute lead_token == person_token
    end

    test "the converted Person masks per plane exactly like any other vaulted field (no leak " <>
           "on the conversion TARGET either)",
         %{org: org, scope: scope} do
      l = new_lead(scope, org, %{full_name: @full_name})
      converted = convert!(l, scope)

      person_with_pii =
        CrmScopeFixture.Person
        |> Ash.Query.filter(id == ^converted.converted_person_id)
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read_one!(scope: scope)

      masked = resolve_on_plane(person_with_pii, CrmScopeFixture.Person, :operator, repo: @repo, grant: DenyAll).full_name
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ "Grace"
      refute to_string(masked) =~ "vt_"
    end

    test "double-convert is REFUSED (RED); the first convert succeeds (CONTROL) — no duplicate " <>
           "Person/Opportunity is ever created",
         %{org: org, scope: scope} do
      l = new_lead(scope, org, %{full_name: @full_name, value: Money.new!(:USD, "100.00")})

      person_count_before = CrmScopeFixture.Person |> Ash.count!(scope: scope, authorize?: false)
      opp_count_before = CrmScopeFixture.Opportunity |> Ash.count!(scope: scope, authorize?: false)

      converted = convert!(l, scope)
      assert converted.status == :converted

      person_count_after_first = CrmScopeFixture.Person |> Ash.count!(scope: scope, authorize?: false)
      opp_count_after_first = CrmScopeFixture.Opportunity |> Ash.count!(scope: scope, authorize?: false)
      assert person_count_after_first == person_count_before + 1
      assert opp_count_after_first == opp_count_before + 1

      assert {:error, _} =
               converted
               |> Ash.Changeset.for_update(:convert, %{}, scope: scope)
               |> Ash.update()

      person_count_after_second = CrmScopeFixture.Person |> Ash.count!(scope: scope, authorize?: false)
      opp_count_after_second = CrmScopeFixture.Opportunity |> Ash.count!(scope: scope, authorize?: false)
      assert person_count_after_second == person_count_after_first
      assert opp_count_after_second == opp_count_after_first
    end

    test "a mid-conversion failure rolls back the WHOLE transaction — Lead stays unconverted, " <>
           "no orphan Person/Opportunity",
         %{org: org, scope: scope} do
      other_org = Ash.UUID.generate()
      other_scope = tenant_scope(other_org)
      foreign_company = new_company(other_scope, other_org)

      l = new_lead(scope, org, %{full_name: @full_name, value: Money.new!(:USD, "9.99")})

      person_count_before = CrmScopeFixture.Person |> Ash.count!(scope: scope, authorize?: false)
      opp_count_before = CrmScopeFixture.Opportunity |> Ash.count!(scope: scope, authorize?: false)

      assert {:error, _} =
               l
               |> Ash.Changeset.for_update(:convert, %{company_id: foreign_company.id}, scope: scope)
               |> Ash.update()

      reread = Ash.get!(Lead, l.id, scope: scope)
      assert reread.status == :new
      assert is_nil(reread.converted_person_id)
      assert is_nil(reread.converted_opportunity_id)

      assert CrmScopeFixture.Person |> Ash.count!(scope: scope, authorize?: false) == person_count_before
      assert CrmScopeFixture.Opportunity |> Ash.count!(scope: scope, authorize?: false) == opp_count_before
    end
  end

  # ── c8: catalog registration ────────────────────────────────────────────────

  describe "c8 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the SalesOps fixture's tables/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "ssv_vendor" or &1 =~ "sls_lead"))

      assert violations == [],
             "expected no catalog_parity violations for the SalesOps fixture tables, got: " <>
               inspect(violations)
    end
  end
end
