defmodule Driftwood.ApiExternalSurfaceTest do
  @moduledoc """
  F1 (Gate-5 carry) — the external-surface guarantees on FREIGHT PII (doc
  §external-surface :693–:730), proven on the RUNNING reference vertical (was proven
  only in `demo` before this).

  The four freight-specific red paths the Gate-5 report names:

    1. a driver's CDL is NEVER plaintext in a JSON:API payload for a cross-tenant
       OPERATOR key (masked-by-default: absent without a live grant), and a masked value
       renders `••••` (never a `vt_` token, never the storage name);
    2. a freight WEBHOOK emits a masked, catalogued payload — the vaulted CDL serializes
       `••••`, storage names (`pii_drv_*`, `drv_*`, `dsp_*`) never leak, and the payload
       is opt-in (a non-allowlisted field / the `custom` bag / `org_id` are ABSENT);
    3. a TENANT key reads its OWN org's driver PII in CLEAR (tenant-as-owner; no grant);
    4. an OPERATOR key with NO grant sees the vaulted CDL ABSENT on a driver.

  Anti-tautology: the tenant-clear path asserts plaintext IS present, and the webhook
  positive control asserts a non-PII allowlisted field IS present — so the "absent" /
  "masked" assertions are non-vacuous. A live anti-tautology sabotage is recorded in the
  Gate-5 F1 report section.
  """
  use Driftwood.ApiCase, async: false

  setup do
    prev = Application.get_env(:samen_core, :reveal_grant)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:samen_core, :reveal_grant)
  defp restore(v), do: Application.put_env(:samen_core, :reveal_grant, v)

  # =========================================================================
  # RED PATH 3 — TENANT key reads its OWN org's driver CDL/name in CLEAR.
  # =========================================================================

  describe "tenant key (two key classes: tenant-as-owner)" do
    test "reads its OWN org's driver CDL + name in CLEAR — no reveal grant involved" do
      org = mk_org()
      cdl = "CDL-CLEAR-TENANT-#{System.unique_integer([:positive])}"
      _d = mk_driver(org, %{cdl_number: cdl, full_name: %{first: "Owned", last: "Driver"}})

      {raw, _key} = mk_api_key(org, plane: :tenant)

      conn = api_get("/drivers", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # The tenant owns its drivers' PII → plaintext, NOT `••••`, NOT absent.
      assert attrs["cdl_number"] == cdl, "tenant key did not read its own driver CDL in clear"
      assert Map.has_key?(attrs, "full_name")
      assert attrs["full_name"] =~ "Owned"
      # The vault token itself NEVER appears.
      refute conn.resp_body =~ "vt_"
    end

    test "a cross-org tenant key sees ZERO of another org's drivers" do
      org_a = mk_org()
      org_b = mk_org()
      _da = mk_driver(org_a, %{full_name: %{first: "Ay", last: "Own"}})
      _db = mk_driver(org_b, %{cdl_number: "CDL-FOREIGN-#{System.unique_integer([:positive])}"})

      {raw_a, _} = mk_api_key(org_a, plane: :tenant)

      conn = api_get("/drivers", raw_a)
      assert conn.status == 200
      %{"data" => data} = json(conn)

      # Only org A's driver(s); org B's CDL never appears.
      refute conn.resp_body =~ "CDL-FOREIGN-"
      # Non-vacuous: org A's own driver IS returned.
      assert length(data) == 1
    end
  end

  # =========================================================================
  # RED PATH 1 + 4 — OPERATOR key: CDL masked/absent by default; •••• never plaintext.
  # =========================================================================

  describe "operator key (two key classes: cross-tenant masked-by-default)" do
    test "vaulted CDL is ABSENT (masked by default) WITHOUT a reveal grant" do
      restore(Samen.Reveal.Grants)

      org = mk_org()
      cdl = "CDL-SECRET-#{System.unique_integer([:positive])}"
      _d = mk_driver(org, %{cdl_number: cdl, full_name: %{first: "Masked", last: "Subject"}})

      {raw, _key} = mk_api_key(org, plane: :operator)

      conn = api_get("/drivers", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # Non-PII fields still present (the record is visible; only PII is withheld).
      assert Map.has_key?(attrs, "status")

      # Vaulted fields ABSENT (operator plane, no grant) — not `••••`, not plaintext.
      refute Map.has_key?(attrs, "cdl_number"),
             "operator key saw the vaulted CDL with no grant"

      refute Map.has_key?(attrs, "full_name"),
             "operator key saw the vaulted name with no grant"

      # The plaintext CDL + the vault token never appear ANYWHERE in the body.
      refute conn.resp_body =~ cdl
      refute conn.resp_body =~ "vt_"
      # The physical storage name never leaks either.
      refute conn.resp_body =~ "pii_drv_cdl_number"
      refute conn.resp_body =~ "drv_cdl"
    end

    test "vaulted CDL is PLAINTEXT with a live distinct-party reveal grant (control)" do
      restore(Samen.Reveal.Grants)

      org = mk_org()
      cdl = "CDL-GRANTED-#{System.unique_integer([:positive])}"
      driver = mk_driver(org, %{cdl_number: cdl})

      {raw, key} = mk_api_key(org, plane: :operator)
      requestor_id = key.minter_user_id

      {:ok, req} =
        Samen.Reveal.Grants.request(%{
          subject_id: to_string(driver.id),
          requestor_id: requestor_id,
          reason: "api integration test"
        })

      {:ok, _grant} =
        Samen.Reveal.Grants.approve(req, %{granted_by: "distinct-approver", window_minutes: 60})

      conn = api_get("/drivers", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # WITH a live grant the operator reads plaintext — proving the absence above was
      # the grant gate, not a blanket strip.
      assert Map.has_key?(attrs, "cdl_number"), "live grant did not surface the vaulted CDL"
      assert attrs["cdl_number"] == cdl
    end
  end

  # =========================================================================
  # RED PATH 2 — the freight WEBHOOK emits a masked, catalogued payload.
  # =========================================================================

  describe "freight webhook payload (opt-in allowlist, masked PII, catalog names only)" do
    test "driver.updated: the vaulted CDL serializes •••• (never plaintext, never a token)" do
      # A masked driver record (an Ash read returns %Masked{} for vault fields) drives
      # the payload. The `••••` is the masked serialization the doc mandates.
      record = %{
        id: "drv-webhook-1",
        cdl_state: "TX",
        cdl_expiry: "2027-01-01",
        medical_card_expiry: ~D[2027-01-01],
        status: :available,
        eld_provider: :samsara,
        org_id: "org-should-not-appear",
        custom: %{"secret" => "should_not_appear"},
        full_name: %Samen.Masked{token: "vt_name_abc", label: :full_name},
        cdl_number: %Samen.Masked{token: "vt_cdl_xyz", label: :cdl_number}
      }

      data = Driftwood.Webhooks.driver_updated(record)["data"]

      # Masked PII serializes as `••••` — never plaintext, never a `vt_` token. The
      # composite `full_name` is the masked-PII vehicle here (its catalog name does not
      # collide with the samen_core webhook storage-name heuristic — see the note below).
      assert data["full_name"] == "••••", "vaulted name must serialize as •••• in the webhook"

      # The vaulted CDL and its token NEVER appear as plaintext anywhere in the payload
      # (fail-safe). A6 FIX (Gate-6): `Samen.Webhook.Payload`'s storage-name guard now
      # keys on the resource's DECLARED abbrev (`drv`), not a blanket `~r/^[a-z]{3}_/`
      # regex. So the legitimate freight CATALOG names that merely START with a 3-letter
      # token + underscore — `cdl_number`, `cdl_state`, `cdl_expiry`, `eld_provider` —
      # now SURVIVE (they are NOT `drv_`/`pii_drv_`-prefixed storage names). The vaulted
      # `cdl_number` survives as its masked `••••` (never plaintext, never a `vt_` token).
      assert data["cdl_number"] == "••••",
             "the vaulted CDL must survive as •••• (A6 fix — no longer dropped by the guard)"

      json = Jason.encode!(data)
      refute json =~ "CDL-", "no plaintext CDL in the webhook body"
      refute json =~ "vt_", "no vault token in the webhook body"

      # A6 red path (1): the previously-dropped non-PII catalog names now SURVIVE under
      # their catalog names (they are legitimately allowlisted; the guard no longer
      # false-positives on the `cdl`/`eld` 3-letter prefixes).
      assert data["cdl_state"] == "TX", "cdl_state (catalog name) must survive the guard"
      assert data["cdl_expiry"] == "2027-01-01", "cdl_expiry (catalog name) must survive"
      assert data["eld_provider"] == "samsara", "eld_provider (catalog name) must survive"

      # Non-vacuous positive control: an allowlisted non-PII field IS present under its
      # CATALOG name.
      assert data["status"] == "available"

      # Opt-in allowlist: org_id + the custom bag are ABSENT by omission.
      refute Map.has_key?(data, "org_id"), "org_id must be absent (opt-in allowlist)"
      refute Map.has_key?(data, "custom"), "the Tier-1 custom bag must be absent (opt-in)"

      # Storage names NEVER appear as keys (the abbrev-prefixed physical columns).
      assert Enum.all?(Map.keys(data), fn k -> not String.starts_with?(k, "pii_") and not String.starts_with?(k, "drv_") end)
    end

    test "load.status: the DispatchEvent payload is opt-in, catalogued, non-PII" do
      record = %{
        id: "dsp-webhook-1",
        status: :in_transit,
        dispatched_at: ~U[2026-07-07 12:00:00Z],
        driver_id: "drv-1",
        load_id: "load-1",
        org_id: "org-should-not-appear",
        custom: %{"note" => "confidential"}
      }

      data = Driftwood.Webhooks.load_status(record)["data"]

      # Allowlisted catalog fields present (non-vacuous).
      assert data["status"] == "in_transit"
      assert data["driver_id"] == "drv-1"
      assert data["load_id"] == "load-1"

      # Opt-in: org_id + custom bag absent by omission.
      refute Map.has_key?(data, "org_id")
      refute Map.has_key?(data, "custom")

      # Storage names never appear.
      assert Enum.all?(Map.keys(data), fn k -> not String.starts_with?(k, "dsp_") end)
    end

    test "the webhook event type is the bounded catalog event name (control)" do
      record = %{id: "dsp-2", status: :delivered, driver_id: "d", load_id: "l"}
      payload = Driftwood.Webhooks.load_status(record)
      assert payload["event"] == "load.status"
      assert payload["type"] == "dispatch_event"
    end
  end

  # =========================================================================
  # RED PATH — fail closed: an actor-less (no key) request sees ZERO rows.
  # =========================================================================

  test "an actor-less request (no api key) sees ZERO driver rows (fail closed)" do
    org = mk_org()
    _d = mk_driver(org, %{cdl_number: "CDL-NOKEY-#{System.unique_integer([:positive])}"})

    conn = api_get("/drivers")
    # No actor → OrgScope nil-org branch → zero rows (or a 4xx). Never a driver row.
    refute conn.resp_body =~ "CDL-NOKEY-"

    case conn.status do
      200 -> assert json(conn)["data"] == []
      other -> assert other in [401, 403, 404]
    end
  end
end
