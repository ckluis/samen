defmodule Demo.ApiAllowlistTest do
  @moduledoc """
  T3.11 — allowlist serialization boundary. The load-bearing controls:

    * fields are OPT-IN via `json_api do show_fields … end` — an undeclared field is
      ABSENT from the payload (default not-exposed);
    * a newly added storage column does NOT appear until explicitly allowlisted
      (`newly added storage column absent` red path);
    * payloads carry CATALOG names (`:full_name`, `:display_name`), NEVER storage
      names (`cnt_full_name`, `pii_cnt_dob`, `com_`, `pii_`) nor vault routing
      (`vt_*` tokens).

  Anti-tautology: the positive controls assert the allowlisted fields DO appear, so
  "absent" is a real omission, not a vacuously-empty payload.
  """
  use Demo.ApiCase, async: false

  # A storage-name pattern the public payload must never leak: an abbrev-prefixed
  # column name (`cnt_*`, `com_*`, `ido_*`, `usr_*`) or a vault prefix/token
  # (`pii_*`, `vt_*`). These are the physical column / vault details the doc says the
  # public schema hides.
  @storage_name_patterns [
    ~r/\bcnt_/,
    ~r/\bcom_/,
    ~r/\bido_/,
    ~r/\busr_/,
    ~r/\bpii_/,
    ~r/\bvt_/
  ]

  describe "allowlist — catalog names only, storage names never" do
    test "a contact payload exposes ONLY the allowlisted catalog fields" do
      org = mk_org("Acme")
      _c = mk_contact(org.id, %{display_name: "Visible One"})
      {raw, _key} = mk_api_key(org.id, plane: :tenant)

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)

      attrs = record["attributes"]

      # Positive control: the allowlisted non-PII fields ARE present (not vacuous).
      assert Map.has_key?(attrs, "display_name")
      assert Map.has_key?(attrs, "active")
      assert attrs["display_name"] == "Visible One"

      # `type` is the catalog name, never the storage table (`cnt_contact`).
      assert record["type"] == "contact"

      # The whole payload carries no storage/vault name anywhere.
      body = conn.resp_body

      for pattern <- @storage_name_patterns do
        refute Regex.match?(pattern, body),
               "storage name #{inspect(pattern)} leaked into API payload: #{body}"
      end
    end

    test "an UNALLOWLISTED public attribute is absent (org_id — the tenant boundary)" do
      org = mk_org("Acme")
      _c = mk_contact(org.id, %{display_name: "HasOrg"})
      {raw, _key} = mk_api_key(org.id, plane: :tenant)

      conn = api_get("/contacts", raw)
      %{"data" => [record | _]} = json(conn)

      # `org_id` is a PUBLIC Ash attribute (Samen.Transformers.CoreAttributes injects
      # it public?: true). Without `show_fields` it WOULD appear. It is deliberately
      # NOT allowlisted → absent by omission. And its value (the org uuid) does not
      # leak into the payload anywhere either.
      refute Map.has_key?(record["attributes"], "org_id"),
             "unallowlisted public attribute `org_id` appeared in the API payload"

      refute conn.resp_body =~ org.id,
             "the org_id value leaked into the payload"
    end

    test "the ?fields= query param cannot force an unallowlisted field to appear" do
      org = mk_org("Acme")
      _c = mk_contact(org.id, %{display_name: "FieldsProbe"})
      {raw, _key} = mk_api_key(org.id, plane: :tenant)

      # A caller asks for org_id explicitly. show_fields is the SCHEMA-level allowlist,
      # so `?fields=` can NEVER widen past it. AshJsonApi fails closed here: either it
      # REJECTS the request naming an un-shown field (4xx), or it returns 200 with the
      # field absent. Both outcomes prove org_id never reaches the payload.
      conn = api_get("/contacts?fields[contact]=org_id,display_name", raw)

      if conn.status == 200 do
        %{"data" => [record | _]} = json(conn)
        refute Map.has_key?(record["attributes"], "org_id"),
               "?fields= forced an unallowlisted field to appear"
      else
        assert conn.status in 400..499
        refute conn.resp_body =~ org.id, "org_id value leaked in the rejection body"
      end
    end
  end
end
