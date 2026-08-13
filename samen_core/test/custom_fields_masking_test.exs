defmodule SamenCore.CustomFieldsMaskingTest do
  @moduledoc """
  ADR-046 §4.2 (D3) — THE `pii_declared` CUSTOM-BAG MASKING RED-PATH.

  A Tier-1 custom field declared `pii_declared: true` stores **plaintext PII in the
  `public?: true` `custom` jsonb bag** (never vault-routed — the honest seam). Before
  this batch, `Samen.Api.PiiResolution` iterated declared `pii_attribute`s ONLY, so the
  bag key flowed to the operator in the CLEAR on every generic surface (CSV / JSON:API /
  kit) — an INV-1 gap the masking watch-list discipline must close.

  Consumer of `Samen.MaskingCase` — the SAME green/red/sabotage three-proof every PII
  surface ships, proving the bag key is now resolved through the SAME plane model
  (`resolve_on_plane/4` → `Samen.Api.PiiResolution.resolve/4`) as a vault field:

    * **GREEN** — the tenant plane resolves the pii_declared bag key to its CLEAR
      plaintext (the tenant owns its org's PII); non-PII bag keys ride along untouched.
    * **RED** — the operator-without-grant plane resolves it to `%Samen.Masked{}`: renders
      exactly `••••`, NEVER the plaintext, NEVER a `vt_*` token — mask-by-omission on the
      KEY (the value replaced), while every non-pii_declared key stays clear (per-key, not
      per-column).
    * **SABOTAGE twins (anti-tautology)** — (1) plane flip: the SAME record on the tenant
      plane goes clear (the resolver is the gate, not a blanket mask); (2) leak scan
      refutability: a modeled unresolved render (the raw bag serialized) DOES leak the
      plaintext and IS caught by the same scan the RED test relies on.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.CustomFields
  alias Samen.Masked
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.TestRepo

  @table "tcf_widget"
  @erasure_spec %{
    table_name: @table,
    bag_column: "tcf_custom",
    subject_column: "tcf_id",
    org_column: "tcf_org_id"
  }

  # The pii_declared plaintext (an email-shaped value — allowed ONLY because the field
  # is pii_declared, which lifts the containment shape-rejection) and a plain non-PII key.
  @secret "alice@example.com"
  @plain "gold"
  @key "care_note"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  # Define a pii_declared bag key + a plain key, then persist a widget whose bag holds
  # plaintext PII in the pii_declared key. Returns the read-back record (bag loaded).
  defp seed_widget!(org_id) do
    {:ok, _} =
      CustomFields.define_field(
        %{
          org_id: org_id,
          table_name: @table,
          field_name: @key,
          type: :string,
          pii_declared: true,
          erasure_specs: [@erasure_spec]
        },
        TestRepo
      )

    {:ok, _} =
      CustomFields.define_field(
        %{org_id: org_id, table_name: @table, field_name: "loyalty_tier", type: :string},
        TestRepo
      )

    {:ok, widget} =
      Widget
      |> Ash.Changeset.for_create(
        :create,
        %{name: "w", org_id: org_id, custom: %{@key => @secret, "loyalty_tier" => @plain}},
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    # Re-read as a framework read surface would (default select — `org_id` is NOT
    # select-by-default, so the record does NOT carry it; the resolver keys off the
    # acting scope's org, exactly like CSV export / a LiveView list).
    Widget
    |> Ash.Query.filter(id == ^widget.id)
    |> Ash.read_one!(authorize?: false)
  end

  # The acting-scope actor shape `Samen.Web.Plane.scope/2` produces: a plane + the
  # tenant-boundary `org_id` (and, for operator, an impersonation marker). This is the
  # REAL source of the read's org (records aren't loaded with `org_id` by default).
  defp tenant_actor(org_id), do: %{plane: :tenant, org_id: org_id}

  defp operator_actor(org_id),
    do: %{plane: :operator, impersonation: %{session_id: "op-session"}, org_id: org_id}

  # INDETERMINATE-org actors: a masking-plane actor that carries NO org_id (and the
  # record, read with the default select, does not carry org_id either) — so the resolver
  # cannot enumerate the pii_declared key set.
  defp operator_actor_no_org, do: %{plane: :operator, impersonation: %{session_id: "op-session"}}
  defp tenant_actor_no_org, do: %{plane: :tenant}

  defp resolve(record, actor) do
    [resolved] = Samen.Api.PiiResolution.resolve([record], Widget, actor, repo: TestRepo)
    resolved
  end

  defp bag_value(record, actor), do: record |> resolve(actor) |> Map.get(:custom) |> Map.get(@key)

  describe "pii_declared bag masking per plane (ADR-046 §4.2 D3)" do
    test "GREEN: the tenant plane resolves the pii_declared bag key in the CLEAR" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      resolved = resolve(widget, tenant_actor(org_id))

      assert_plane_clear!(resolved.custom[@key], @secret)
      # Non-PII key rides along unmasked on every plane.
      assert resolved.custom["loyalty_tier"] == @plain
    end

    test "RED: the operator-without-grant plane resolves the bag key to •••• (never plaintext, never a token)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      resolved = resolve(widget, operator_actor(org_id))

      masked = resolved.custom[@key]
      assert_plane_masked!(masked, @secret)

      # Masking is PER-KEY: the plain (non-pii_declared) key is untouched.
      assert resolved.custom["loyalty_tier"] == @plain

      # No serialization path emits the plaintext or a vt_* token: the whole resolved
      # bag JSON-encodes with `••••` in the pii_declared key and the plaintext absent.
      json = Jason.encode!(resolved.custom)
      assert json =~ Samen.MaskingCase.mask()
      refute json =~ @secret
      refute json =~ "vt_"
      # The plain key survives in the JSON (proving per-key, not blanket).
      assert json =~ @plain
    end

    test "ANTI-TAUTOLOGY: the SAME record on the two planes — tenant clear ∧ operator masked (plane flip)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      tenant_value = bag_value(widget, tenant_actor(org_id))
      operator_value = bag_value(widget, operator_actor(org_id))

      # The only difference between the two reads is the plane — proving the mask is the
      # resolver's per-plane decision, not a serialize-everything-as-•••• blanket.
      assert_two_plane!(tenant_value, operator_value, @secret)
    end

    test "ANTI-TAUTOLOGY: a modeled unresolved render IS caught by the plaintext leak scan" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      # A broken surface that serialized the AT-REST bag WITHOUT resolution would write
      # the plaintext into the payload. Model exactly that leak and prove the scan the
      # RED test relies on (`refute json =~ @secret`) is refutable.
      leaked = Jason.encode!(widget.custom)
      assert_leak_detected!(leaked, @secret)
    end

    test "the masked bag value carries NO token (a bag key is not vault-routed)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      masked = bag_value(widget, operator_actor(org_id))
      assert %Masked{token: nil} = masked
      assert to_string(masked) == Samen.MaskingCase.mask()
      refute to_string(masked) =~ "vt_"
    end
  end

  # ==========================================================================
  # ADR-046 §4.2 D3 — FAIL-CLOSED when the pii_declared key set is INDETERMINATE
  # ==========================================================================

  describe "fail-closed whole-bag mask on an indeterminate masking plane (ADR-046 §4.2 D3)" do
    test "RED: operator-without-grant + indeterminate org → the WHOLE bag renders •••• (no plaintext, no token)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      # Masking plane, but neither the actor nor the (default-selected) record carries
      # org_id — the resolver cannot enumerate which keys are pii_declared, so it must NOT
      # emit ANY bag value in the clear. EVERY key masks (fail-closed), including the
      # otherwise-non-PII key.
      resolved = resolve(widget, operator_actor_no_org())

      assert_plane_masked!(resolved.custom[@key], @secret)
      assert_plane_masked!(resolved.custom["loyalty_tier"], @plain)

      json = Jason.encode!(resolved.custom)
      assert json =~ Samen.MaskingCase.mask()
      refute json =~ @secret
      # Even the non-PII value is withheld when we cannot vet the bag.
      refute json =~ @plain
      refute json =~ "vt_"
    end

    test "POSITIVE CONTROL (a): the SAME indeterminate scenario on the TENANT plane stays CLEAR (no over-mask)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      # Tenant plane: bag plaintext is legitimately allowed, so the indeterminate-org
      # fail-closed branch is NEVER reached — the bag rides clear. This proves the
      # fail-closed masking is refutable AND does not over-mask the non-masking plane.
      resolved = resolve(widget, tenant_actor_no_org())

      assert resolved.custom[@key] == @secret
      assert resolved.custom["loyalty_tier"] == @plain
    end

    test "POSITIVE CONTROL (b): with the org KNOWN, the determinate per-key path is unchanged (non-PII rides clear)" do
      org_id = Ash.UUID.generate()
      widget = seed_widget!(org_id)

      # The determinate operator-no-grant path (actor carries org_id) masks ONLY the
      # pii_declared key — the non-PII key stays clear. Contrast with the fail-closed
      # whole-bag mask above: the difference is solely whether the org is resolvable.
      resolved = resolve(widget, operator_actor(org_id))

      assert_plane_masked!(resolved.custom[@key], @secret)
      assert resolved.custom["loyalty_tier"] == @plain
    end
  end
end
