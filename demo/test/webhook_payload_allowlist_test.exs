defmodule Demo.WebhookPayloadAllowlistTest do
  @moduledoc """
  F3.6 — the webhook payload serializer honors an explicit OPT-IN allowlist.

  `Samen.Webhook.Payload.build/3` includes a field ONLY IF its catalog name is on the
  resource's `show_fields` allowlist (the SAME allowlist the public API surface uses).
  A field absent from `show_fields` — a public non-PII field, the Tier-1 `:custom`
  jsonb bag, the injected `org_id`/`inserted_at`/`updated_at` — is ABSENT from the
  payload by omission. This is the doc's (§external-surface `:711`) "a resource's
  columns are not auto-published to the API OR webhook surface … the default is
  not-exposed" mandate, on the webhook surface.

  These tests run against REAL Ash resources (`Demo.Crm.Contact`, the F3.6 fixture
  `Demo.WebhookAllowlist.Widget`) — the serializer reads `show_fields` off the resource
  module and values off the record struct, so no DB round-trip is needed to prove the
  allowlist filter.

  Red paths (Gate-3 F3.6):
    1. A public non-PII field NOT on the allowlist (`org_id`, `internal_label`) is ABSENT.
    2. The Tier-1 `custom` bag is ABSENT even when populated with data.
    3. An allowlisted field appears under its catalog name (positive control — the
       "absent" assertions are not vacuous).
    4. Masked PII on the allowlist serializes as "••••" / omitted per the plane rules.
  """
  use ExUnit.Case, async: true

  alias Samen.Webhook.Payload
  alias Samen.Masked

  describe "F3.6 RED PATH 1 — a public field NOT on show_fields is ABSENT" do
    test "org_id (public, NOT allowlisted) is absent from the Contact payload" do
      # org_id is injected public?: true but deliberately kept off Contact's
      # show_fields([:id, :display_name, :active, :full_name, :emails, :dob]).
      record = %{
        id: "cnt-1",
        display_name: "Acme",
        active: true,
        org_id: "org-should-not-appear",
        full_name: %Masked{token: "vt_name", label: :full_name},
        emails: %Masked{token: "vt_email", label: :emails},
        dob: %Masked{token: "vt_dob", label: :dob}
      }

      data = Payload.build("contact.created", Demo.Crm.Contact, record)["data"]

      refute Map.has_key?(data, "org_id"),
             "org_id is public but NOT on show_fields — it MUST be absent from the webhook payload (F3.6 opt-in)"
    end

    test "a public field off the allowlist (internal_label) is absent" do
      record = %{
        id: "waw-1",
        display_name: "Widget One",
        internal_label: "should_not_appear"
      }

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      refute Map.has_key?(data, "internal_label"),
             "internal_label is public but NOT on show_fields — MUST be absent (F3.6 opt-in)"
    end
  end

  describe "F3.6 RED PATH 2 — the Tier-1 custom bag is ABSENT even when populated" do
    test "custom bag with data does NOT appear in the payload" do
      record = %{
        id: "waw-2",
        display_name: "Widget Two",
        # Populated Tier-1 bag — the exact leak Gate-3 F3.6 flagged.
        custom: %{"priority" => "high", "tenant_note" => "confidential"}
      }

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      refute Map.has_key?(data, "custom"),
             "The Tier-1 `custom` jsonb bag is NOT on show_fields — it MUST be absent " <>
               "from the webhook payload even when populated (F3.6 opt-in; the doc's " <>
               "'columns are not auto-published to the webhook surface' mandate)"
    end
  end

  describe "F3.6 RED PATH 3 — an allowlisted field DOES appear (positive control)" do
    test "display_name (on show_fields) appears under its catalog name" do
      record = %{id: "waw-3", display_name: "Visible Widget", internal_label: "hidden"}

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      assert Map.get(data, "display_name") == "Visible Widget",
             "display_name IS on show_fields — it must appear under its catalog name " <>
               "(proves the 'absent' assertions are non-vacuous)"
    end

    test "allowlisted Contact non-PII fields appear; the rest are absent" do
      record = %{
        id: "cnt-2",
        display_name: "Acme Corp",
        active: true,
        org_id: "org-x",
        full_name: %Masked{token: "vt_name", label: :full_name},
        emails: %Masked{token: "vt_email", label: :emails},
        dob: %Masked{token: "vt_dob", label: :dob}
      }

      data = Payload.build("contact.created", Demo.Crm.Contact, record)["data"]

      # allowlisted non-PII
      assert data["display_name"] == "Acme Corp"
      assert data["active"] == true
      assert data["id"] == "cnt-2"
      # not allowlisted
      refute Map.has_key?(data, "org_id")
    end
  end

  describe "F3.6 RED PATH 4 — masked PII on the allowlist serializes per plane rules" do
    test "allowlisted masked PII serializes as ••••" do
      record = %{
        id: "cnt-3",
        display_name: "Acme",
        active: true,
        org_id: "org-x",
        full_name: %Masked{token: "vt_name", label: :full_name},
        emails: %Masked{token: "vt_email", label: :emails},
        dob: %Masked{token: "vt_dob", label: :dob}
      }

      data = Payload.build("contact.created", Demo.Crm.Contact, record)["data"]

      assert data["full_name"] == "••••", "allowlisted masked PII must serialize as ••••"
      assert data["emails"] == "••••"
      assert data["dob"] == "••••"
    end

    test "allowlisted PII absent (operator-plane, no grant → nil/ForbiddenField) is omitted" do
      # On the operator plane without a grant, PII resolves to absent (nil).
      # An absent PII value must be OMITTED, not emitted as null.
      record = %{
        id: "cnt-4",
        display_name: "Acme",
        active: true,
        org_id: "org-x",
        full_name: nil,
        emails: nil,
        dob: nil
      }

      data = Payload.build("contact.created", Demo.Crm.Contact, record)["data"]

      refute Map.has_key?(data, "full_name"), "absent (nil) PII must be omitted, not null"
      refute Map.has_key?(data, "emails")
      refute Map.has_key?(data, "dob")
      # the non-PII allowlisted fields are still present
      assert data["display_name"] == "Acme"
    end

    test "include_masked: false omits masked PII entirely" do
      record = %{
        id: "cnt-5",
        display_name: "Acme",
        active: true,
        full_name: %Masked{token: "vt_name", label: :full_name},
        emails: %Masked{token: "vt_email", label: :emails},
        dob: %Masked{token: "vt_dob", label: :dob}
      }

      data =
        Payload.build("contact.created", Demo.Crm.Contact, record, include_masked: false)["data"]

      refute Map.has_key?(data, "full_name")
      assert data["display_name"] == "Acme"
    end
  end

  describe "A6 (Gate-6) — the storage-name guard keys on the DECLARED abbrev, not a blanket 3-letter regex" do
    test "RED PATH 1 — a catalog name that starts with a 3-letter token+underscore SURVIVES" do
      # `cdl_number` is a legitimate catalog name, allowlisted, that HAPPENS to start
      # with a 3-letter token + underscore (`cdl_`). The OLD `~r/^[a-z]{3}_/` guard
      # silently DROPPED it (the A6 false-positive). The abbrev-keyed guard (Widget's
      # declared abbrev is `waw`, not `cdl`) must let it survive under its catalog name.
      record = %{id: "waw-a6-1", display_name: "Widget", cdl_number: "CDL-12345"}

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      assert data["cdl_number"] == "CDL-12345",
             "a catalog name starting with a 3-letter token+underscore must SURVIVE " <>
               "(A6 fix — the guard keys on the resource's abbrev `waw`, not `cdl`)"

      # Non-vacuous positive control: a plain allowlisted field is also present.
      assert data["display_name"] == "Widget"
    end

    test "RED PATH 2 — a name starting with THIS resource's own abbrev (`waw_`) is STILL stripped" do
      # `waw_leaked_col` is a genuine storage-name-shaped field: it starts with the
      # resource's OWN declared abbrev (`waw`). Even though it was (mistakenly)
      # allowlisted, the abbrev-keyed guard must STILL strip it — catalog names only.
      record = %{
        id: "waw-a6-2",
        display_name: "Widget",
        cdl_number: "CDL-999",
        waw_leaked_col: "should_not_appear"
      }

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      refute Map.has_key?(data, "waw_leaked_col"),
             "a name starting with the resource's own abbrev prefix (`waw_`) is a storage " <>
               "name and MUST be stripped even if allowlisted"

      # Non-vacuous: the abbrev-shaped drop did NOT also drop the legit catalog name.
      assert data["cdl_number"] == "CDL-999"
      assert data["display_name"] == "Widget"
    end

    test "RED PATH 3 — the opt-in allowlist STILL governs (a non-allowlisted field is absent)" do
      # A6 composes WITH the Phase-3 opt-in allowlist: `internal_label` is public but
      # NOT allowlisted, so it is absent regardless of the storage-name guard.
      record = %{
        id: "waw-a6-3",
        display_name: "Widget",
        cdl_number: "CDL-1",
        internal_label: "not_allowlisted"
      }

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      refute Map.has_key?(data, "internal_label"),
             "a non-allowlisted field is still absent — the opt-in allowlist is the primary gate"

      assert data["cdl_number"] == "CDL-1"
    end

    test "RED PATH 4 — masked PII still serializes as •••• (composes with A6)" do
      # A masked value on an allowlisted catalog field (whose name also trips the old
      # 3-letter shape) still masks as •••• — the A6 fix does not disturb PII masking.
      record = %{
        id: "waw-a6-4",
        display_name: "Widget",
        cdl_number: %Masked{token: "vt_cdl_abc", label: :cdl_number}
      }

      data = Payload.build("widget.created", Demo.WebhookAllowlist.Widget, record)["data"]

      assert data["cdl_number"] == "••••",
             "a masked value on a surviving catalog field still serializes as •••• (never plaintext)"

      json = Jason.encode!(data)
      refute json =~ "vt_", "no vault token in the payload body"
    end
  end

  describe "F3.6 — no show_fields → empty data (fail-closed)" do
    test "a resource with an empty/absent allowlist auto-publishes NOTHING" do
      # Demo.Crm.Membership has no show_fields declared → allowlist is empty →
      # the payload data map is empty (nothing auto-published).
      record = %{id: "mbr-1", org_id: "org-x", contact_id: "cnt-x", role: :owner}

      data = Payload.build("membership.created", Demo.Crm.Membership, record)["data"]

      assert data == %{},
             "a resource with no show_fields must produce an EMPTY data map (fail-closed; " <>
               "nothing auto-published) — got: #{inspect(data)}"
    end
  end
end
