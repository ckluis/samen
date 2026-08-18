defmodule Samen.Billing.PaymentMethodTest do
  @moduledoc """
  B5 payment methods (T23; ADR-038 §3.1 `create_portal_session`, §3.5 no-PAN +
  customer-sync-whitelist rules) — the CORE, vendor-generic half, proven
  hermetically against a call-recording spy provider (no samen_stripe
  dependency needed here; the REAL Stripe HTTP-form proof lives in
  `samen_stripe/test/payment_method_test.exs`).

  Done-criteria covered here:
    * required attrs refuse BEFORE any provider call;
    * `return_url` is ALWAYS org-scoped (same guard as `Checkout`'s redirects);
    * the outbound attrs are reduced to a CLOSED whitelist — junk keys the
      caller passes never reach the provider (done-criterion 3, the CORE half
      of the customer-sync whitelist; the ADAPTER half is proven in
      samen_stripe);
    * unconfigured fail-honest passthrough (ADR-014).
  """
  use ExUnit.Case, async: true

  alias Samen.Billing.PaymentMethod

  @org_id "org_pm_1"
  @customer_ref "cus_pm_1"

  # A call-recording SPY provider (not a real Ash resource, not samen_stripe) —
  # captures exactly what `PaymentMethod` forwards, proving the whitelist for
  # real rather than trusting the module's own claim.
  defmodule SpyProvider do
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(config), do: Map.get(config, :configured?, true)

    @impl true
    def create_portal_session(attrs, config) do
      if configured?(config) do
        send(config.test_pid, {:portal_attrs, attrs})
        {:ok, %{url: "https://billing.example.test/session/abc"}}
      else
        {:error, :not_configured}
      end
    end

    @impl true
    def create_checkout_session(_attrs, _config), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_id, _opts, _config), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_id, _changes, _config), do: {:error, :not_implemented}
    @impl true
    def fetch_object(_kind, _id, _config), do: {:error, :not_implemented}
    @impl true
    def report_usage(_batch, _config), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_body, _headers, _config), do: {:error, :not_implemented}
    @impl true
    def redact_payload(payload), do: payload
  end

  defp portal_attrs(overrides \\ %{}) do
    Map.merge(
      %{org_id: @org_id, customer_ref: @customer_ref, return_url: "https://app.example.test/billing"},
      overrides
    )
  end

  # PP-5 (Batch 2 TENANT-ROLE): the portal is a billing WRITE — admin+ by construction.
  # The default actor is an admin (the positive control every non-role test threads); the
  # role-gate tests pass `actor:` explicitly to prove denial by ROLE.
  defp admin_actor(role \\ :admin),
    do: %{id: "u_billing", org_id: @org_id, role: role, kind: :tenant, plane: :tenant}

  defp create_portal_session(attrs, config_overrides \\ %{}, opts \\ []) do
    config = Map.merge(%{test_pid: self()}, config_overrides)
    actor = Keyword.get(opts, :actor, admin_actor())
    PaymentMethod.create_portal_session(attrs, provider: SpyProvider, provider_config: config, actor: actor)
  end

  # ---------------------------------------------------------------------------
  # Required attrs.
  # ---------------------------------------------------------------------------

  describe "required attrs" do
    test "missing required attrs refuse BEFORE any provider call" do
      assert {:error, {:missing_attrs, missing}} = create_portal_session(%{org_id: @org_id})
      assert :customer_ref in missing
      assert :return_url in missing
      refute_received {:portal_attrs, _}
    end

    test "a fully-formed call succeeds and returns the provider's hosted URL" do
      assert {:ok, %{url: url}} = create_portal_session(portal_attrs())
      assert url == "https://billing.example.test/session/abc"
      assert_received {:portal_attrs, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Org-scoping — the SAME anti-cross-tenant-redirect guard Checkout applies.
  # ---------------------------------------------------------------------------

  describe "return_url is ALWAYS org-scoped" do
    test "the org_id query param is FORCED onto return_url" do
      assert {:ok, _} = create_portal_session(portal_attrs())

      assert_received {:portal_attrs, attrs}
      uri = URI.parse(attrs.return_url)
      assert URI.decode_query(uri.query) == %{"org_id" => @org_id}
    end

    test "a caller-spoofed org_id in return_url is OVERWRITTEN by the authoritative org_id" do
      spoofed =
        portal_attrs(%{return_url: "https://app.example.test/billing?org_id=attacker_org&ref=xyz"})

      assert {:ok, _} = create_portal_session(spoofed)

      assert_received {:portal_attrs, attrs}
      query = URI.decode_query(URI.parse(attrs.return_url).query)
      assert query["org_id"] == @org_id
      refute query["org_id"] == "attacker_org"
      assert query["ref"] == "xyz"
    end
  end

  # ---------------------------------------------------------------------------
  # done-criterion 3 (CORE half) — the outbound attrs are a CLOSED whitelist.
  # ---------------------------------------------------------------------------

  describe "the outbound attrs are reduced to a CLOSED whitelist before the provider ever sees them" do
    test "billing_name/billing_email pass through when present (the vault-resolved sync fields)" do
      assert {:ok, _} =
               create_portal_session(portal_attrs(%{billing_name: "Alice Accountant", billing_email: "alice@billing.example"}))

      assert_received {:portal_attrs, attrs}
      assert attrs.billing_name == "Alice Accountant"
      assert attrs.billing_email == "alice@billing.example"
    end

    test "ANY key outside the whitelist is DROPPED — junk attrs never reach the provider" do
      junky =
        portal_attrs(%{
          billing_name: "Bob Banker",
          card_number: "4242424242424242",
          cvc: "123",
          phone: "+15551234567",
          address: "1 Main St",
          random_junk: "should never survive"
        })

      assert {:ok, _} = create_portal_session(junky)

      assert_received {:portal_attrs, attrs}
      assert Enum.sort(Map.keys(attrs)) == Enum.sort([:org_id, :customer_ref, :return_url, :billing_name])
      refute Map.has_key?(attrs, :card_number)
      refute Map.has_key?(attrs, :cvc)
      refute Map.has_key?(attrs, :phone)
      refute Map.has_key?(attrs, :address)
      refute Map.has_key?(attrs, :random_junk)
    end

    test "omitting billing_name/billing_email is a pure no-op — no sync fields forwarded" do
      assert {:ok, _} = create_portal_session(portal_attrs())

      assert_received {:portal_attrs, attrs}
      refute Map.has_key?(attrs, :billing_name)
      refute Map.has_key?(attrs, :billing_email)
    end

    test "blank billing_name/billing_email are treated as absent, not forwarded as empty strings" do
      assert {:ok, _} = create_portal_session(portal_attrs(%{billing_name: "", billing_email: nil}))

      assert_received {:portal_attrs, attrs}
      refute Map.has_key?(attrs, :billing_name)
      refute Map.has_key?(attrs, :billing_email)
    end
  end

  # ---------------------------------------------------------------------------
  # PP-5 (Batch 2 TENANT-ROLE) — the portal is admin-gated BY CONSTRUCTION (by ROLE, not
  # plane): opening it changes the card / cancels the subscription. Both directions.
  # ---------------------------------------------------------------------------

  describe "create_portal_session/2 — admin-by-construction role gate (PP-5)" do
    # SABOTAGE-adjacent: dropping `authorize_admin/1` on the portal lets a member open the
    # Stripe portal — this assertion FLIPS from `:unauthorized` to `{:ok, ...}`.
    test "PP-5: a MEMBER actor is DENIED the portal at the function layer, BEFORE any provider call" do
      assert {:error, :unauthorized} = create_portal_session(portal_attrs(), %{}, actor: admin_actor(:member))
      refute_received {:portal_attrs, _}
    end

    test "PP-5: a VIEWER actor is DENIED the portal (read-only cannot change the card)" do
      assert {:error, :unauthorized} = create_portal_session(portal_attrs(), %{}, actor: admin_actor(:viewer))
      refute_received {:portal_attrs, _}
    end

    test "PP-5: an ABSENT/nil actor is DENIED — fail-closed (no actor param at all)" do
      assert {:error, :unauthorized} =
               PaymentMethod.create_portal_session(portal_attrs(), provider: SpyProvider, provider_config: %{test_pid: self()})

      refute_received {:portal_attrs, _}
    end

    test "PP-5: an ADMIN actor is ALLOWED (positive control — reaches the provider)" do
      assert {:ok, %{url: _}} = create_portal_session(portal_attrs(), %{}, actor: admin_actor(:admin))
      assert_received {:portal_attrs, _}
    end

    test "PP-5: an OWNER actor is ALLOWED (owner outranks admin)" do
      assert {:ok, %{url: _}} = create_portal_session(portal_attrs(), %{}, actor: admin_actor(:owner))
      assert_received {:portal_attrs, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-honest passthrough (ADR-014).
  # ---------------------------------------------------------------------------

  describe "fail-honest: unconfigured refuses (passthrough, never faked)" do
    test "the provider's :not_configured refusal passes straight through (under an ADMIN actor — no false denial)" do
      assert {:error, :not_configured} = create_portal_session(portal_attrs(), %{configured?: false})
      refute_received {:portal_attrs, _}
    end
  end
end
