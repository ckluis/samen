defmodule SamenCore.CustomFieldsRichTypesTest do
  @moduledoc """
  ADR-036 H6/D6 (T15 done-criterion 1): the five Tier-1 custom-field kinds this
  task adds — `money`/`url`/`phone`/`email`/`address` — reusing the matching
  `Samen.Type.*` module's cast/validation logic, same bounded-constraint
  discipline as the pre-existing six (`custom_fields_test.exs`).

  Three groups, mirroring that file's shape:

    * ACCEPT vectors — one per new type, a valid value defines + writes clean.
    * bounded-CONSTRAINT rejection vectors — one per new type, an in-shape but
      out-of-bound value is REJECTED (anti-tautology: the in-bound sibling is
      accepted on the SAME field).
    * containment (H6 contract: "a custom email/phone/address field can never
      become a vault bypass") — proves the TYPE-based gate `Samen.CustomFields`
      gained, not just the pre-existing value-shape heuristic:
        - an `:address` value (a MAP — invisible to the string-only shape
          heuristic) on a non-`pii_declared` field is still refused;
        - a `:phone` value SHORT enough to dodge the heuristic's 3-3-4 grouping
          regex is still refused on a non-`pii_declared` field;
        - the SAME values on a `pii_declared: true` field are ALLOWED
          (discriminating, not a blanket deny);
        - the non-PII new kinds (`money`/`url`) carry NO such gate — a plain
          value is allowed un-declared (anti-tautology: the gate is type-scoped,
          not applied to everything).
  """
  use ExUnit.Case, async: false

  alias Samen.CustomFields
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.TestRepo

  @table "tcf_widget"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp org, do: Ash.UUID.generate()

  defp define!(org_id, field, type, opts \\ []) do
    {:ok, row} =
      CustomFields.define_field(
        Enum.into(opts, %{
          org_id: org_id,
          table_name: @table,
          field_name: field,
          type: type,
          # ADR-046 §4.2 D3: wire the custom-bag erasure arm so the pii_declared
          # rich-type defines below satisfy the erasability guard (compliant host).
          erasure_specs: [%{table_name: @table, subject_column: "tcf_id", org_column: "tcf_org_id"}]
        }),
        TestRepo
      )

    row
  end

  defp create_widget(org_id, custom) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: "w", org_id: org_id, custom: custom},
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  defp error_msg(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&Exception.message/1) |> Enum.join(" | ")
  end

  defp error_msg(other), do: inspect(other)

  # ==========================================================================
  # ACCEPT vectors — one per new type (field_types/0 done-criterion 1)
  # ==========================================================================

  describe "H6 ACCEPT: five new field types write clean" do
    test "field_types/0 lists all five" do
      assert :money in CustomFields.field_types()
      assert :url in CustomFields.field_types()
      assert :phone in CustomFields.field_types()
      assert :email in CustomFields.field_types()
      assert :address in CustomFields.field_types()
    end

    test "money — a valid \"CUR amount\" string is accepted" do
      o = org()
      define!(o, "deal_value", :money)
      assert {:ok, w} = create_widget(o, %{"deal_value" => "USD 1234.50"})
      assert w.custom["deal_value"] == "USD 1234.50"
    end

    test "url — a valid absolute http(s) URL is accepted" do
      o = org()
      define!(o, "homepage", :url)
      assert {:ok, w} = create_widget(o, %{"homepage" => "https://example.test/x"})
      assert w.custom["homepage"] == "https://example.test/x"
    end

    test "phone — declared pii_declared: true, a valid E.164-ish number is accepted" do
      o = org()
      define!(o, "office_phone", :phone, pii_declared: true)
      assert {:ok, w} = create_widget(o, %{"office_phone" => "+15550100100"})
      assert w.custom["office_phone"] == "+15550100100"
    end

    test "email — declared pii_declared: true, a valid email is accepted" do
      o = org()
      define!(o, "contact_email", :email, pii_declared: true)
      assert {:ok, w} = create_widget(o, %{"contact_email" => "person@example.test"})
      assert w.custom["contact_email"] == "person@example.test"
    end

    test "address — declared pii_declared: true, a valid (partial) address map is accepted" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true)

      assert {:ok, w} =
               create_widget(o, %{"mailing_address" => %{"city" => "Springfield", "country" => "us"}})

      assert w.custom["mailing_address"]["city"] == "Springfield"
    end
  end

  # ==========================================================================
  # REJECT — the base shape check (garbage never coerced)
  # ==========================================================================

  describe "H6 REJECT: base shape check" do
    test "money — an unparseable string is rejected" do
      o = org()
      define!(o, "deal_value", :money)
      assert {:error, err} = create_widget(o, %{"deal_value" => "not money"})
      assert error_msg(err) =~ "not a money"
    end

    test "url — a relative / scheme-less string is rejected" do
      o = org()
      define!(o, "homepage", :url)
      assert {:error, err} = create_widget(o, %{"homepage" => "not-a-url"})
      assert error_msg(err) =~ "not a url"
    end

    test "address — a non-map value is rejected" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true)
      assert {:error, err} = create_widget(o, %{"mailing_address" => "123 Main St"})
      assert error_msg(err) =~ "not a address"
    end

    test "address — a malformed country code is rejected (the type's own format rule)" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true)
      assert {:error, err} = create_widget(o, %{"mailing_address" => %{"country" => "USA"}})
      assert error_msg(err) =~ "not a address"
    end
  end

  # ==========================================================================
  # Bounded-constraint REJECTION vectors (done-criterion 1, "incl.
  # bounded-constraint rejection vectors") — one per new type, discriminating
  # (the in-bound value on the SAME field is accepted).
  # ==========================================================================

  describe "H6 bounded-constraint rejection vectors" do
    test "money — a currency outside the tenant's :currencies allowlist is rejected" do
      o = org()
      define!(o, "deal_value", :money, constraints: %{currencies: ["USD"]})

      assert {:error, err} = create_widget(o, %{"deal_value" => "EUR 10.00"})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"deal_value" => "USD 10.00"})
    end

    test "url — a tightened :schemes allowlist rejects an otherwise-valid http URL" do
      o = org()
      define!(o, "homepage", :url, constraints: %{schemes: ["https"]})

      assert {:error, err} = create_widget(o, %{"homepage" => "http://example.test/insecure"})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"homepage" => "https://example.test/secure"})
    end

    test "url — :max_length rejects an over-long URL" do
      o = org()
      define!(o, "homepage", :url, constraints: %{max_length: 20})

      long = "https://example.test/#{String.duplicate("x", 30)}"
      assert {:error, err} = create_widget(o, %{"homepage" => long})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"homepage" => "https://example.test"})
    end

    test "phone — :max_length rejects an over-long (pre-normalization) number" do
      o = org()
      define!(o, "office_phone", :phone, pii_declared: true, constraints: %{max_length: 8})

      assert {:error, err} = create_widget(o, %{"office_phone" => "+1 (555) 010-0100"})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"office_phone" => "15550100"})
    end

    test "email — :max_length rejects an over-long address" do
      o = org()
      define!(o, "contact_email", :email, pii_declared: true, constraints: %{max_length: 10})

      assert {:error, err} = create_widget(o, %{"contact_email" => "way-too-long@example.test"})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"contact_email" => "a@bb.com"})
    end

    test "address — an :allowed_countries allowlist rejects an out-of-list country" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true, constraints: %{allowed_countries: ["US", "CA"]})

      assert {:error, err} = create_widget(o, %{"mailing_address" => %{"country" => "fr"}})
      assert error_msg(err) =~ "constraint violated"

      assert {:ok, _} = create_widget(o, %{"mailing_address" => %{"country" => "us"}})
    end

    test "address — a partial address with NO country is unaffected by :allowed_countries (optional field)" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true, constraints: %{allowed_countries: ["US"]})

      assert {:ok, w} = create_widget(o, %{"mailing_address" => %{"city" => "Springfield"}})
      assert w.custom["mailing_address"]["city"] == "Springfield"
    end
  end

  # ==========================================================================
  # Containment — "a custom email/phone/address field can never become a vault
  # bypass" (H6 contract), proving the TYPE-based gate (not just the
  # pre-existing value-shape heuristic).
  # ==========================================================================

  describe "H6 containment: email/phone/address are PII-BY-TYPE, not merely by shape" do
    test "RED — an address MAP on a non-pii_declared field is rejected (invisible to the string-only shape heuristic)" do
      o = org()
      define!(o, "mailing_address", :address)

      assert {:error, err} =
               create_widget(o, %{"mailing_address" => %{"city" => "Springfield", "country" => "US"}})

      assert error_msg(err) =~ "PII-shaped"
      assert error_msg(err) =~ "vault bypass"
    end

    test "RED — a SHORT phone number that does NOT match the value-shape heuristic's 3-3-4 regex is still rejected" do
      o = org()
      define!(o, "office_phone", :phone)

      # 8 digits, no separators — Samen.Type.PhoneNumber accepts it (8-15 digit
      # E.164-ish), but Samen.PiiValueShape's phone regex (grouped 3-3-4) does
      # NOT match it — proving the gate is type-scoped, not heuristic-dependent.
      refute Samen.PiiValueShape.pii_shaped_id?("15550100")

      assert {:error, err} = create_widget(o, %{"office_phone" => "15550100"})
      assert error_msg(err) =~ "PII-shaped"
      assert error_msg(err) =~ "vault bypass"
    end

    test "RED — a plain email on a non-pii_declared field is rejected (baseline, matches the pre-existing heuristic too)" do
      o = org()
      define!(o, "contact_email", :email)

      assert {:error, err} = create_widget(o, %{"contact_email" => "person@example.test"})
      assert error_msg(err) =~ "PII-shaped"
    end

    test "GREEN — the SAME address/phone/email values on pii_declared: true fields are ALLOWED (discriminating, not blanket-deny)" do
      o = org()
      define!(o, "mailing_address", :address, pii_declared: true)
      define!(o, "office_phone", :phone, pii_declared: true)
      define!(o, "contact_email", :email, pii_declared: true)

      assert {:ok, w} =
               create_widget(o, %{
                 "mailing_address" => %{"city" => "Springfield", "country" => "US"},
                 "office_phone" => "15550100",
                 "contact_email" => "person@example.test"
               })

      assert w.custom["mailing_address"]["city"] == "Springfield"
      assert w.custom["office_phone"] == "15550100"
      assert w.custom["contact_email"] == "person@example.test"
    end

    test "ANTI-TAUTOLOGY — money/url (non-PII-by-type) carry NO containment gate: a plain un-declared value is allowed" do
      o = org()
      define!(o, "deal_value", :money)
      define!(o, "homepage", :url)

      assert {:ok, w} =
               create_widget(o, %{"deal_value" => "USD 42.00", "homepage" => "https://example.test"})

      assert w.custom["deal_value"] == "USD 42.00"
      assert w.custom["homepage"] == "https://example.test"
    end
  end
end
