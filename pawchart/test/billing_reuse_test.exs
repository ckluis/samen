defmodule PawChart.BillingReuseTest do
  @moduledoc """
  The REUSE proof for T6.2's additive case: PawChart's Billing is the samen_core Billing
  scope MOUNTED AS-IS — plain subscriptions, NO reshape, NO Samen.Context, NO
  alias_resource. This test exercises the inherited Billing surface with ZERO PawChart
  billing code and confirms:

    * a clinic bills a monthly SUBSCRIPTION exactly as the kernel models it (Customer🔒 →
      Plan → Price → Subscription), no vertical money model;
    * the customer🔒 name/email are vault-routed and masked (inherited PII vault);
    * the entitlement helper (`Samen.Scopes.Billing.Entitlement.entitled?/3`) — pure
      substrate — answers a feature-gate for the clinic's plan.

  This is the load-bearing contrast the vision doc draws: Driftwood had to RESHAPE
  Invoice into settlement netting under an anti-corruption layer; PawChart adds nothing —
  the whole Billing model is inherited.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  alias Samen.Scopes.Billing.Entitlement

  @org "00000000-0000-0000-0000-0000000000f1"

  test "a clinic bills a plain monthly subscription (Customer🔒 → Plan → Price → Subscription)" do
    customer =
      PawChart.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        billing_name: "Happy Paws Veterinary Clinic LLC",
        billing_email: "ap@happypaws.example.com"
      })
      |> Ash.create!(authorize?: false)

    plan =
      PawChart.Billing.Plan
      |> Ash.Changeset.for_create(:create, %{org_id: @org, name: "clinic_pro", interval: :monthly})
      |> Ash.create!(authorize?: false)

    _price =
      PawChart.Billing.Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        plan_id: plan.id,
        # ADR-036 §4.5: unit_amount_cents/currency dropped by the H1 Money migration.
        unit_amount: Samen.Type.Money.from_cents(9900, :USD)
      })
      |> Ash.create!(authorize?: false)

    subscription =
      PawChart.Billing.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        customer_id: customer.id,
        plan_id: plan.id,
        status: :active
      })
      |> Ash.create!(authorize?: false)

    assert subscription.status == :active
    assert subscription.customer_id == customer.id
    assert subscription.plan_id == plan.id
  end

  test "the customer🔒 billing_name/email are vault-routed + masked (inherited PII vault)" do
    customer =
      PawChart.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        billing_name: "Vault Test Clinic",
        billing_email: "secret@clinic.example.com"
      })
      |> Ash.create!(authorize?: false)

    # RAW physical column holds a vault token, not the plaintext.
    %{rows: [[raw_email]]} =
      Ecto.Adapters.SQL.query!(
        PawChart.Repo,
        "SELECT pii_pbc_billing_email FROM pbc_customer WHERE pbc_id = $1",
        [Ecto.UUID.dump!(to_string(customer.id))]
      )

    assert String.starts_with?(raw_email, "vt_")
    refute raw_email =~ "secret@clinic.example.com"

    # A normal read masks.
    read =
      PawChart.Billing.Customer
      |> Ash.Query.filter(id == ^customer.id)
      |> Ash.Query.ensure_selected([:billing_email])
      |> Ash.read_one!(authorize?: false)

    assert match?(%Samen.Masked{}, read.billing_email)
  end

  test "the inherited entitlement helper answers a feature gate for the clinic's plan" do
    customer =
      PawChart.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{org_id: @org, billing_name: "Entitlement Helper Clinic"})
      |> Ash.create!(authorize?: false)

    plan =
      PawChart.Billing.Plan
      |> Ash.Changeset.for_create(:create, %{org_id: @org, name: "clinic_basic"})
      |> Ash.create!(authorize?: false)

    subscription =
      PawChart.Billing.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: @org,
        customer_id: customer.id,
        plan_id: plan.id,
        status: :active
      })
      |> Ash.create!(authorize?: false)

    # The clinic uses the INHERITED product-feature vocabulary (:api_access, :sso, …) —
    # an honest edge of the additive case: PawChart reuses the substrate's feature-gate
    # model as-is; a vet-specific feature key would be a Tier-1 custom extension, not a
    # billing reshape.
    PawChart.Billing.Entitlement
    |> Ash.Changeset.for_create(:create, %{
      org_id: @org,
      subscription_id: subscription.id,
      plan_id: plan.id,
      feature: :api_access,
      granted: true
    })
    |> Ash.create!(authorize?: false)

    # Pure substrate helper — no PawChart code.
    assert {:ok, true} =
             Entitlement.entitled?(@org, :api_access, PawChart.Billing.Entitlement, repo: PawChart.Repo)

    assert {:ok, false} =
             Entitlement.entitled?(@org, :sso, PawChart.Billing.Entitlement, repo: PawChart.Repo)
  end
end
