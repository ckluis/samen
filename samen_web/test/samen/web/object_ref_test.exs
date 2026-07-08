defmodule Samen.Web.ObjectRefTest do
  @moduledoc """
  Framework object-unfurl UNIT tests (ADR-012 §4, test-plan §8.5): the ref grammar (`parse/1`),
  ref↔resource translation (`Catalog`), and the catalog-driven `DefaultCard` proving the
  framework promise — a NEVER-BEFORE-SEEN catalogued resource unfurls masked-correctly on the
  operator plane via the default card, with NO override written.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.ObjectRef
  alias Samen.Web.ObjectRef.{Catalog, DefaultCard, Registry}

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, seeded: seeded}
  end

  # ==========================================================================
  # parse/1 — the ref grammar
  # ==========================================================================

  describe "parse/1" do
    test "extracts a well-formed samen:<key>:<uuid> ref out of surrounding text" do
      id = "0f00aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      text = "please look at samen:crm.person:#{id} before the call"

      assert [%ObjectRef{key: "crm.person", id: ^id, raw: raw}] = ObjectRef.parse(text)
      assert raw == "samen:crm.person:#{id}"
    end

    test "extracts multiple refs, in order, de-duplicated" do
      a = Ash.UUID.generate()
      b = Ash.UUID.generate()

      text = "samen:crm.person:#{a} and samen:support.ticket:#{b} and again samen:crm.person:#{a}"

      refs = ObjectRef.parse(text)
      assert length(refs) == 2
      assert Enum.map(refs, & &1.key) == ["crm.person", "support.ticket"]
    end

    test "IGNORES a bare UUID with no samen: prefix (no false positives)" do
      assert ObjectRef.parse("here is a bare id #{Ash.UUID.generate()} in the text") == []
    end

    test "ignores a samen: ref whose id is not UUID-shaped" do
      assert ObjectRef.parse("samen:crm.person:not-a-uuid") == []
    end

    test "nil / empty text yields no refs" do
      assert ObjectRef.parse(nil) == []
      assert ObjectRef.parse("") == []
    end

    test "round-trips to_string/2 -> parse/1 -> from_string/1" do
      id = Ash.UUID.generate()
      str = ObjectRef.to_string("crm.person", id)
      assert str == "samen:crm.person:#{id}"
      assert {:ok, %ObjectRef{key: "crm.person", id: ^id}} = ObjectRef.from_string(str)
    end
  end

  # ==========================================================================
  # Catalog — ref key ↔ resource module (derive-from-namespace)
  # ==========================================================================

  describe "Catalog.key_for/1 + resource_for/2" do
    test "key_for/1 is the last two module segments, lowercased + dotted" do
      assert Catalog.key_for(Samen.WebTest.Crm.Person) == "crm.person"
      assert Catalog.key_for(Samen.WebTest.Support.Ticket) == "support.ticket"
      assert Catalog.key_for(Samen.WebTest.Billing.Invoice) == "billing.invoice"
    end

    test "resource_for/2 derives the host resource from the mount namespace" do
      mount = build_mount(:crm)
      assert {:ok, Samen.WebTest.Crm.Person} = Catalog.resource_for(mount, "crm.person")
    end

    test "resource_for/2 resolves a DIFFERENT scope's resource from the same host root" do
      # A :crm mount can resolve a support.ticket ref (cross-scope, same host root).
      mount = build_mount(:crm)
      assert {:ok, Samen.WebTest.Support.Ticket} = Catalog.resource_for(mount, "support.ticket")
      assert {:ok, Samen.WebTest.Billing.Invoice} = Catalog.resource_for(mount, "billing.invoice")
    end

    test "resource_for/2 returns :unknown_key for a non-existent resource" do
      mount = build_mount(:crm)
      assert {:error, :unknown_key} = Catalog.resource_for(mount, "crm.bogus")
      assert {:error, :unknown_key} = Catalog.resource_for(mount, "bogus.thing")
    end

    test "resource_for/2 returns :unknown_key for a malformed key" do
      mount = build_mount(:crm)
      assert {:error, :unknown_key} = Catalog.resource_for(mount, "notdotted")
      assert {:error, :unknown_key} = Catalog.resource_for(mount, "a.b.c")
    end
  end

  # ==========================================================================
  # DefaultCard — the framework promise (a resource with NO override still masks)
  # ==========================================================================

  describe "DefaultCard (catalog-driven) on a resource with NO override" do
    test "renders a title + fields for a non-PII resource (company via default card)", %{
      org_id: org_id,
      seeded: seeded
    } do
      # crm.company HAS a first-class card; to prove the DEFAULT path we call DefaultCard
      # directly with a resolved company record (non-PII).
      mount = build_mount(:crm)
      scope = Mount.scope(mount, org_id)

      {:ok, card} =
        ObjectRef.resolve(mount, scope, %ObjectRef{
          key: "crm.company",
          id: seeded.crm.company.id,
          raw: "samen:crm.company:#{seeded.crm.company.id}"
        })

      # crm.company IS a framework override — assert it via Registry below; here assert the
      # DefaultCard renders a company record directly.
      default = DefaultCard.card("crm.company", Samen.WebTest.Crm.Company, seeded.crm.company)
      assert default.title == "Northwind Freight Co"
      assert default.key == "crm.company"
      # The override card produced by resolve/3 also titles the company.
      assert card.title == "Northwind Freight Co"
    end

    test "THE FRAMEWORK PROMISE: a vaulted-field resource with NO override masks on operator via DefaultCard", %{
      org_id: org_id,
      seeded: seeded
    } do
      # Prove the default card masks a PII field correctly WITHOUT any override. We resolve
      # the person record on the OPERATOR plane (so full_name/emails are %Masked{}) and build
      # the DEFAULT card from it — the default card must render •••• for the vaulted title.
      mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
      scope = Mount.scope(mount, org_id)

      # Load + resolve exactly as resolve/3 does, but build the DEFAULT card (not the override).
      person = load_resolved(Samen.WebTest.Crm.Person, seeded.crm.person.id, scope, mount)
      assert match?(%Samen.Masked{}, person.full_name)

      card = DefaultCard.card("crm.person", Samen.WebTest.Crm.Person, person)

      # The default card's TITLE is the masked full_name → renders •••• (no override needed).
      # This is the framework promise: a VAULTED field is the face of the card and masks on the
      # operator plane, via the SAME resolver, with ZERO override written.
      assert match?(%Samen.Masked{}, card.title)

      # Every VAULTED field on the person (emails/phones) is %Masked{} in the card's body —
      # the `pii do` declaration is honored transitively (the resolver masked them in step 3).
      vaulted_field_values =
        card.fields
        |> Enum.filter(fn {label, _v} -> label in ["Emails", "Phones"] end)
        |> Enum.map(fn {_l, v} -> v end)

      assert vaulted_field_values != []
      assert Enum.all?(vaulted_field_values, &match?(%Samen.Masked{}, &1))

      # The clear EMAIL/PHONE plaintext is absent from the whole card (only display_name, a
      # NON-vaulted kernel attribute, is clear — see the note test below).
      refute Enum.any?(card.fields, fn {_l, v} -> v == Seeds.contact_email() end)
      refute Enum.any?(card.fields, fn {_l, v} -> v == Seeds.contact_phone() end)
    end

    test "the FIRST-CLASS person card (override) surfaces NO clear identity on the operator plane", %{
      org_id: org_id,
      seeded: seeded
    } do
      # The default card renders the non-PII `display_name` clear (the kernel does not classify
      # it as PII). The first-class `Cards.Person` override is deliberately tighter: it titles
      # with the VAULTED full_name and does NOT surface display_name, so an operator card carries
      # NO clear identity at all. resolve/3 selects the override for crm.person.
      mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
      scope = Mount.scope(mount, org_id)

      ref = %ObjectRef{key: "crm.person", id: seeded.crm.person.id, raw: "samen:crm.person:x"}
      {:ok, card} = ObjectRef.resolve(mount, scope, ref)

      assert match?(%Samen.Masked{}, card.title)
      # No field value equals the clear name/email/phone.
      values = Enum.map(card.fields, fn {_l, v} -> v end) ++ [card.title, card.subtitle]
      refute Enum.any?(values, &(&1 == Seeds.contact_full_name()))
      refute Enum.any?(values, &(&1 == Seeds.contact_email()))
      refute Enum.any?(values, &(&1 == Seeds.contact_phone()))
    end
  end

  # ==========================================================================
  # Registry — override vs default selection (data, not code)
  # ==========================================================================

  describe "Registry" do
    test "framework first-class cards are registered for the inherited scopes" do
      mount = build_mount(:crm)
      assert Registry.card_module(mount, "crm.person") == Samen.Web.ObjectRef.Cards.Person
      assert Registry.card_module(mount, "support.ticket") == Samen.Web.ObjectRef.Cards.Ticket
      # A key with no override → nil → the default card renders.
      assert Registry.card_module(mount, "crm.activity") == nil
    end

    test "a host :object_cards mount label WINS over the framework set (the vertical seam)" do
      defmodule FakeDriverCard do
        def card(key, _resource, record), do: %Samen.Web.ObjectRef.Card{key: key, id: record.id, title: "DRIVER"}
      end

      labels = %{object_cards: %{"crm.person" => FakeDriverCard}}
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: labels)

      # Host override beats the framework Person card.
      assert Registry.card_module(mount, "crm.person") == FakeDriverCard
    end
  end

  # -- helpers -----------------------------------------------------------------

  # Load + PII-resolve a record exactly as the resolver does (for direct DefaultCard tests).
  defp load_resolved(resource, id, scope, mount) do
    require Ash.Query

    attrs = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

    [record] =
      resource
      |> Ash.Query.ensure_selected(attrs)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)

    [resolved] =
      Samen.Api.PiiResolution.resolve([record], resource, scope.actor, repo: mount.repo)

    resolved
  end
end
