defmodule Samen.Webhook.PayloadTest.FakeResource do
  @moduledoc false
  # A real Ash resource so `Ash.Resource.Info.attributes/1` works. It has no
  # AshJsonApi extension and thus no `show_fields` — the F3.6 opt-in allowlist
  # resolves to empty, exercising the fail-closed path in samen_core.
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false

  attributes do
    uuid_primary_key(:id, writable?: true, public?: true)
    attribute(:display_name, :string, public?: true)
    attribute(:status, :atom, public?: true)
    attribute(:cnt_internal, :string, public?: true)
    attribute(:pii_secret, :string, public?: true)
    attribute(:org_display_name, :string, public?: true)
    attribute(:abc_storage_col, :string, public?: true)
    attribute(:internal_notes, :string, public?: false)
  end

  actions do
    defaults([:read])
  end
end

defmodule Samen.Webhook.PayloadTest do
  @moduledoc """
  Tests for `Samen.Webhook.Payload` — F3.6 OPT-IN allowlist + PII masking.

  The webhook payload serializer is OPT-IN: a field is included ONLY IF its catalog
  name is on the resource's `show_fields` allowlist (the same allowlist the public API
  surface uses). A field absent from `show_fields` — INCLUDING the Tier-1 `:custom`
  bag, `org_id`, `inserted_at`, `updated_at`, and any plaintext-at-rest column — is
  ABSENT by omission.

  `show_fields` is resolved via `AshJsonApi.Resource.Info` — an OPTIONAL dep that only
  host apps (e.g. `demo`) carry, NOT `samen_core`. So the full show_fields red paths
  (a public non-PII field absent, the `custom` bag absent, an allowlisted field
  present, masked PII per plane) run against real Ash resources in
  `demo/test/webhook_payload_allowlist_test.exs`.

  Here in samen_core (no AshJsonApi loaded) the allowlist is always empty, so these
  tests exercise the FAIL-CLOSED path — with no `show_fields`, NOTHING is
  auto-published — plus the encode + Masked-encoder helpers that are host-independent.
  """
  use ExUnit.Case, async: true

  alias Samen.Webhook.Payload
  alias Samen.Masked
  alias Samen.Webhook.PayloadTest.FakeResource

  describe "build/3 — basic structure" do
    test "produces event/id/type/data keys" do
      record = %{id: "rec-123", display_name: "Acme Corp", status: :active}
      payload = Payload.build("invoice.created", FakeResource, record)

      assert payload["event"] == "invoice.created"
      assert payload["id"] == "rec-123"
      assert is_binary(payload["type"])
      assert is_map(payload["data"])
    end
  end

  describe "FAIL-CLOSED — no show_fields allowlist (samen_core: no AshJsonApi) → empty data" do
    test "public fields are NOT auto-published without an allowlist" do
      # Every attribute here is public?: true. With no resolvable `show_fields`
      # (AshJsonApi absent in samen_core), the opt-in allowlist is empty, so the
      # data map is EMPTY — nothing is auto-published. This is the inverse of the
      # old opt-OUT-by-pattern behavior Gate-3 F3.6 flagged.
      record = %{
        id: "rec-1",
        display_name: "Acme",
        status: :active,
        cnt_internal: "should_not_appear",
        pii_secret: "also_absent",
        internal_notes: "private"
      }

      data = Payload.build("contact.created", FakeResource, record)["data"]

      assert data == %{},
             "With no opt-in allowlist, the payload data must be EMPTY (fail-closed; " <>
               "nothing auto-published) — got: #{inspect(data)}"
    end

    test "a populated field is absent when the resource declares no allowlist" do
      record = %{id: "r1", display_name: "Test", org_display_name: "Org", abc_storage_col: "v"}

      data = Payload.build("test.event", FakeResource, record)["data"]

      refute Map.has_key?(data, "display_name"),
             "no allowlist → even a plain catalog field is absent (opt-in default not-exposed)"

      refute Map.has_key?(data, "abc_storage_col")
      refute Map.has_key?(data, "org_display_name")
    end
  end

  describe "encode/1" do
    test "produces valid JSON" do
      payload = %{"event" => "test.event", "id" => "123", "type" => "test", "data" => %{}}
      assert {:ok, json} = Payload.encode(payload)
      assert {:ok, _} = Jason.decode(json)
    end
  end

  describe "Masked encoder" do
    test "%Masked{} JSON-encodes as ••••" do
      assert {:ok, json} =
               Payload.encode(%{"data" => %{"email" => %Masked{token: "vt", label: :email}}})

      assert json =~ "••••" or json =~ "\\u2022"
    end
  end
end
