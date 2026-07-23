defmodule SamenStripe.ProviderTest do
  @moduledoc """
  ADR-038 §3.2 fail-honest table for `SamenStripe.Provider` (T18/B1 skeleton).

  Coverage:
    * `configured?/1` is driven strictly by `config[:secret_key]` presence.
    * Every callback except `configured?/1` and `redact_payload/1` refuses with
      `{:error, :not_configured}` when unconfigured — a table test, one row per
      callback, per the ADR-014/ADR-038 fail-honest shape (mirrors
      `samen_core/test/delivery_adapter_test.exs` / `files_storage_test.exs`).
    * Anti-tautology: a CONFIGURED provider does NOT silently claim success either
      — it returns the honest `:not_implemented` (the real HTTP dispatch is
      operator/T19-T21 work), proving `configured?/1` is a genuine gate and not a
      constant that always returns the same error regardless of config.
    * `redact_payload/1` does real work (not config-gated) and is proven
      non-trivial: it actually strips known PII keys, and leaves non-PII data
      (including nested maps/lists) untouched.
    * This package compiles + runs standalone: its only path dep is samen_core.
  """
  use ExUnit.Case, async: true

  alias SamenStripe.Provider

  @unconfigured %{}
  @configured %{secret_key: "sk_test_123"}

  describe "configured?/1" do
    test "false without a secret_key" do
      refute Provider.configured?(%{})
      refute Provider.configured?(%{secret_key: ""})
      refute Provider.configured?(%{secret_key: nil})
    end

    test "true with a non-empty secret_key" do
      assert Provider.configured?(@configured)
    end
  end

  # ---------------------------------------------------------------------------
  # ADR-038 §3.2 fail-honest table: unconfigured -> :not_configured, NEVER a
  # fake {:ok, _}. Table-driven so every callback is proven, not just a sample.

  describe "fail-honest table: unconfigured refuses every callback (never a fake :ok)" do
    test "every callback (except configured?/1 and redact_payload/1) returns {:error, :not_configured}" do
      table = [
        {"create_checkout_session", Provider.create_checkout_session(%{}, @unconfigured)},
        {"create_checkout_session (fully-formed attrs)",
         Provider.create_checkout_session(
           %{
             org_id: "org_1",
             plan_id: "plan_1",
             price_ref: "price_1",
             success_url: "https://app.example.test/success",
             cancel_url: "https://app.example.test/cancel"
           },
           @unconfigured
         )},
        {"create_portal_session (WIRED, T23) — still :not_configured when unconfigured",
         Provider.create_portal_session(%{}, @unconfigured)},
        {"cancel_subscription", Provider.cancel_subscription("sub_1", [], @unconfigured)},
        {"change_subscription", Provider.change_subscription("sub_1", %{}, @unconfigured)},
        {"fetch_object", Provider.fetch_object(:customer, "cus_1", @unconfigured)},
        {"report_usage", Provider.report_usage([%{}], @unconfigured)},
        {"verify_and_parse_event", Provider.verify_and_parse_event("{}", [], @unconfigured)}
      ]

      for {name, result} <- table do
        assert match?({:error, :not_configured}, result),
               "#{name} must refuse with {:error, :not_configured} when unconfigured, got: #{inspect(result)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-tautology: configured returns the HONEST :not_implemented (real HTTP
  # dispatch is out of B1 scope) — proving :not_configured above is a real gate.

  describe "anti-tautology: configured does not silently succeed OR return the same unconfigured error" do
    # The STILL-SKELETON callbacks (owned by later tasks) return the honest
    # :not_implemented when configured — proving :not_configured above is a real gate
    # and not a constant. B3/T21 has since WIRED fetch_object/cancel_subscription/
    # change_subscription, so those moved to lifecycle_sync_test (real HTTP path,
    # injected transport); they are NO LONGER in this skeleton table.
    test "every still-skeleton callback configured returns :not_implemented (not :not_configured, not a fake :ok)" do
      table = [
        # verify_and_parse_event is IMPLEMENTED, but @configured carries no webhook_secret,
        # so the honest capability-absent answer is :not_implemented (not a fake accept).
        {"verify_and_parse_event", Provider.verify_and_parse_event("{}", [], @configured)}
      ]

      for {name, result} <- table do
        assert match?({:error, :not_implemented}, result),
               "#{name} configured must return {:error, :not_implemented} (never a fake :ok, never the unconfigured error), got: #{inspect(result)}"
      end
    end

    test "the WIRED B3 callbacks no longer refuse when configured (they attempt real work)" do
      # With a cassette transport injected they do real work (lifecycle_sync_test); the
      # point here is only that they are no longer the constant :not_implemented skeleton.
      cfg = Map.put(@configured, :transport, fn _req -> {:ok, %{status: 404, body: %{}}} end)

      assert Provider.fetch_object(:subscription, "sub_x", cfg) == {:error, :not_found}
      assert Provider.cancel_subscription("sub_x", [], cfg) == {:error, :not_found}

      assert Provider.change_subscription("sub_x", %{price_ref: "price_x"}, cfg) ==
               {:error, :not_found}
    end

    test "the WIRED B2 create_checkout_session no longer refuses as :not_implemented when configured" do
      # Empty attrs: configured, so the honest answer is a VALIDATION refusal — never
      # the unconfigured error, never :not_implemented, never a fake {:ok, _}
      # (real HTTP + payload assembly lives in checkout_test.exs).
      assert {:error, {:missing_attrs, missing}} =
               Provider.create_checkout_session(%{}, @configured)

      assert :org_id in missing
      assert :price_ref in missing
    end

    test "the WIRED B8 report_usage no longer refuses as :not_implemented when configured" do
      # A malformed/empty batch item: configured, so the honest answer is the
      # per-record validation refusal — never the unconfigured error, never
      # :not_implemented, never a fake {:ok, _} (real HTTP + batching/idempotency
      # live in usage_test.exs).
      assert {:error, :missing_provider_ref} = Provider.report_usage([%{}], @configured)
      # An empty batch is a true, honest no-op (nothing to report) — never an error.
      assert {:ok, %{reported: 0}} = Provider.report_usage([], @configured)
    end

    test "the WIRED B5 create_portal_session no longer refuses as :not_implemented when configured" do
      # Empty attrs: configured, so the honest answer is a VALIDATION refusal — never
      # the unconfigured error, never :not_implemented, never a fake {:ok, _}
      # (real HTTP + payload assembly + the customer-sync whitelist proof live in
      # payment_method_test.exs).
      assert {:error, {:missing_attrs, missing}} =
               Provider.create_portal_session(%{}, @configured)

      assert :customer_ref in missing
      assert :return_url in missing
    end
  end

  # ---------------------------------------------------------------------------
  # redact_payload/1 — ALLOWLIST (T24 hardening; ADR-038 §5.4 / INV-1), pure,
  # config-independent, and genuinely non-trivial.
  #
  # The ORIGINAL implementation was a denylist of known-bad key names — it
  # missed PII under any key it hadn't enumerated (e.g. a Stripe `metadata`
  # bag, which is free-form org-authored data: `metadata.customer_email` could
  # carry a real PII value under a key the denylist never named). This
  # describe block proves the allowlist inversion: known-safe SCALAR keys
  # survive; EVERYTHING else — including any nested structure, even one that
  # happens to sit under an allowlisted key name — is dropped.

  describe "redact_payload/1 — allowlist keeps only known-safe scalar keys" do
    test "keeps allowlisted scalar fields, drops unenumerated top-level PII-shaped keys" do
      payload = %{
        "id" => "in_123",
        "object" => "invoice",
        "status" => "open",
        "amount_due" => 4900,
        "currency" => "usd",
        "customer" => "cus_abc",
        # None of these are on the allowlist — dropped regardless of name.
        "customer_email" => "person@example.com",
        "customer_name" => "Person One",
        "phone" => "+15551234567",
        "receipt_email" => "receipts@example.com"
      }

      redacted = Provider.redact_payload(payload)

      assert redacted["id"] == "in_123"
      assert redacted["amount_due"] == 4900
      assert redacted["currency"] == "usd"
      assert redacted["customer"] == "cus_abc"
      refute Map.has_key?(redacted, "customer_email")
      refute Map.has_key?(redacted, "customer_name")
      refute Map.has_key?(redacted, "phone")
      refute Map.has_key?(redacted, "receipt_email")
    end

    test "drops a free-form metadata bag WHOLESALE — any nested key, PII or not" do
      payload = %{
        "id" => "in_dunning_1",
        "amount_due" => 5000,
        "billing_details" => %{
          "email" => "leak@example.com",
          "address" => %{"line1" => "1 Main St"}
        },
        "metadata" => %{
          # A genuinely UNENUMERATED PII key an org could stash in free-form
          # metadata — the exact shape a denylist can never fully enumerate.
          "account_holder_ssn" => "123-45-6789",
          "customer_email" => "hidden-in-metadata@example.com",
          "internal_note" => "not PII, but still dropped — metadata is opaque"
        }
      }

      redacted = Provider.redact_payload(payload)

      assert redacted["id"] == "in_dunning_1"
      assert redacted["amount_due"] == 5000
      refute Map.has_key?(redacted, "billing_details")
      refute Map.has_key?(redacted, "metadata")
    end

    test "an expanded (nested) value under an ALLOWLISTED key is still dropped" do
      # `customer` is normally an opaque string ref, but Stripe CAN return an
      # expanded object under the same key — the allowlist checks the VALUE
      # shape too, never trusting a safe key name alone.
      payload = %{
        "id" => "sub_1",
        "customer" => %{"id" => "cus_1", "email" => "expanded-leak@example.com"}
      }

      redacted = Provider.redact_payload(payload)

      assert redacted["id"] == "sub_1"
      refute Map.has_key?(redacted, "customer")
    end

    test "runs even when the provider is unconfigured (pure function, no creds needed)" do
      assert %{"amount_due" => 100} =
               Provider.redact_payload(%{"amount_due" => 100, "customer_email" => "x@y.com"})
    end
  end
end
