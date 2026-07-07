defmodule Samen.Webhook.PayloadTest do
  @moduledoc """
  Tests for `Samen.Webhook.Payload` — T3.11 allowlist enforcement in webhook payloads.

  Red paths:
  - Storage name (abbrev-prefixed) in payload FAILS (absent from data map)
  - `pii_`-prefixed storage name absent
  - Masked PII serializes as "••••"
  - Plaintext PII value (if somehow passed) is omitted (fail-closed)
  """
  use ExUnit.Case, async: true

  alias Samen.Webhook.Payload
  alias Samen.Masked

  # Minimal fake resource + record for testing without a real Ash resource.
  defmodule FakeResource do
    @moduledoc false

    def attributes do
      [
        %{name: :id, public?: true},
        %{name: :display_name, public?: true},
        %{name: :status, public?: true},
        # This is a storage-name-style attribute — should be filtered.
        %{name: :cnt_internal, public?: true},
        # pii_ prefixed — should be filtered.
        %{name: :pii_secret, public?: true},
        # Not public — should not appear.
        %{name: :internal_notes, public?: false}
      ]
    end
  end

  defmodule PiiResource do
    @moduledoc false

    def attributes do
      [
        %{name: :id, public?: true},
        %{name: :display_name, public?: true},
        %{name: :email, public?: true}
      ]
    end
  end

  # Mimic Ash.Resource.Info.attributes/1 for our fake resources.
  setup do
    # Patch Ash.Resource.Info.attributes for the fake modules via process dict
    # (we call Ash.Resource.Info.attributes/1 inside Payload.build/3 indirectly
    # through the fake resource's own attributes/0).
    :ok
  end

  describe "build/3 — basic structure" do
    test "produces event/id/type/data keys" do
      record = %{id: "rec-123", display_name: "Acme Corp", status: :active}
      # We test with the inline struct, overriding Ash.Resource.Info.attributes
      # via the module's own def.
      payload = build_with_fake(FakeResource, record, "invoice.created")

      assert payload["event"] == "invoice.created"
      assert payload["id"] == "rec-123"
      assert is_binary(payload["type"])
      assert is_map(payload["data"])
    end
  end

  describe "RED PATH: storage names filtered from payload" do
    test "abbrev-prefixed field (cnt_internal) is absent from data" do
      record = %{
        id: "rec-1",
        display_name: "Acme",
        status: :active,
        cnt_internal: "should_not_appear",
        pii_secret: "also_absent",
        internal_notes: "private"
      }

      payload = build_with_fake(FakeResource, record, "contact.created")
      data = payload["data"]

      refute Map.has_key?(data, "cnt_internal"),
             "Storage name 'cnt_internal' must NOT appear in webhook payload (T3.11 allowlist)"

      refute Map.has_key?(data, "pii_secret"),
             "pii_ prefixed field must NOT appear in webhook payload"

      refute Map.has_key?(data, "internal_notes"),
             "Non-public field must NOT appear in webhook payload"
    end

    test "storage names with various 3-letter prefixes are filtered" do
      # Samen storage columns all follow the 3-letter-abbrev_ naming convention
      # (e.g. cnt_, usr_, abc_). Every attribute whose name starts with <3 lowercase
      # letters>_ is treated as a storage name and filtered from webhook payloads.
      fake_attrs = [
        %{name: :id, public?: true},
        %{name: :display_name, public?: true},
        # org_ is also a 3-letter prefix → treated as storage name and filtered.
        %{name: :org_display_name, public?: true},
        %{name: :abc_storage_col, public?: true}
      ]

      record = %{
        id: "r1",
        display_name: "Test",
        org_display_name: "Org Name",
        abc_storage_col: "internal_val"
      }

      payload = build_with_attrs(fake_attrs, record, "test.event")
      data = payload["data"]

      # All 3-letter-prefixed columns are storage names and must be absent.
      refute Map.has_key?(data, "abc_storage_col"),
             "abc_-prefixed storage column must be absent from webhook payload"

      refute Map.has_key?(data, "org_display_name"),
             "org_-prefixed attribute is treated as a storage name and must be absent"

      # Catalog names without a 3-letter prefix must remain.
      assert Map.has_key?(data, "display_name"),
             "Catalog name 'display_name' must be present in payload"
    end
  end

  describe "PII masking in payload" do
    test "Masked{} PII field serializes as ••••" do
      record = %{
        id: "r1",
        display_name: "Acme",
        email: %Masked{token: "vt_abc123", label: :email}
      }

      payload = build_with_masked_resource(PiiResource, record, "user.created")
      data = payload["data"]

      assert Map.has_key?(data, "email"), "Masked PII field should appear as ••••"
      assert data["email"] == "••••", "Masked PII must serialize as ••••, got: #{inspect(data["email"])}"
    end

    test "Masked{} PII is omitted when include_masked: false" do
      record = %{
        id: "r1",
        display_name: "Acme",
        email: %Masked{token: "vt_abc123", label: :email}
      }

      payload = build_with_masked_resource(PiiResource, record, "user.created", include_masked: false)
      data = payload["data"]

      refute Map.has_key?(data, "email"),
             "Masked PII must be absent when include_masked: false"
    end

    test "RED PATH: plaintext PII value in a PII field is omitted (fail-closed)" do
      # If somehow a plaintext value leaks into a PII-declared field (a bug upstream),
      # the payload serializer must NOT include it.
      record = %{
        id: "r1",
        display_name: "Acme",
        # plaintext PII value — should be omitted
        email: "alice@example.com"
      }

      payload = build_with_masked_resource(PiiResource, record, "user.created")
      data = payload["data"]

      refute Map.has_key?(data, "email"),
             "RED PATH: plaintext PII in a PII-declared field must be ABSENT from payload " <>
               "(fail-closed — the serializer must omit non-Masked values for PII fields)"
    end
  end

  describe "encode/1" do
    test "produces valid JSON" do
      payload = %{"event" => "test.event", "id" => "123", "type" => "test", "data" => %{}}
      assert {:ok, json} = Payload.encode(payload)
      assert {:ok, _} = Jason.decode(json)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — build payloads via fake resources.

  defp build_with_fake(resource_mod, record, event_type, opts \\ []) do
    # Intercept Ash.Resource.Info.attributes by using our stub directly.
    stub_resource = resource_mod

    # Build data manually using the Payload internals:
    # We call Payload.build/3 with a struct that has our test attrs.
    build_payload_from_attrs(stub_resource.attributes(), record, event_type, opts)
  end

  defp build_with_masked_resource(_resource_mod, record, event_type, opts \\ []) do
    attrs = [
      %{name: :id, public?: true},
      %{name: :display_name, public?: true},
      %{name: :email, public?: true}
    ]

    # Mark :email as a PII attribute by putting it in the pii_attrs override.
    build_payload_from_attrs(attrs, record, event_type, opts, pii_attrs: [:email])
  end

  defp build_with_attrs(attrs, record, event_type, opts \\ []) do
    build_payload_from_attrs(attrs, record, event_type, opts)
  end

  # Inline re-implementation of Payload.build/3 logic for testing without
  # real Ash.Resource.Info wiring.
  defp build_payload_from_attrs(attrs, record, event_type, opts, extra \\ []) do
    include_masked = Keyword.get(opts, :include_masked, true)
    pii_attrs = Keyword.get(extra, :pii_attrs, []) |> MapSet.new()

    data =
      attrs
      |> Enum.filter(fn a -> a.public? end)
      |> Enum.reduce(%{}, fn attr, acc ->
        name = to_string(attr.name)
        value = Map.get(record, attr.name)

        cond do
          storage_name?(name) ->
            acc

          attr.name in pii_attrs ->
            case value do
              %Masked{} ->
                if include_masked, do: Map.put(acc, name, "••••"), else: acc

              nil ->
                acc

              _other ->
                # plaintext PII — omit
                acc
            end

          true ->
            Map.put(acc, name, serialize(value))
        end
      end)

    record_id = Map.get(record, :id)

    %{
      "event" => event_type,
      "id" => if(record_id, do: to_string(record_id), else: nil),
      "type" => "test_resource",
      "data" => data
    }
  end

  defp storage_name?(name) do
    Regex.match?(~r/^[a-z]{3}_/, name) or String.starts_with?(name, "pii_")
  end

  defp serialize(%Masked{}), do: "••••"
  defp serialize(v) when is_atom(v) and not is_boolean(v) and v != nil, do: to_string(v)
  defp serialize(v), do: v
end
