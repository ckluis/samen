defmodule Driftwood.DemoSeedsTest do
  @moduledoc """
  Covers `Driftwood.Seeds.demo_all/1` — the seed that POPULATES the inherited
  universal-scope pages (CRM · Billing · Support) with freight-flavored data for a
  brokerage tenant org (product thesis: "build the 20% freight, inherit the 80%").

  Asserts:
    * every inherited scope is populated with a realistic row count;
    * the invoice mix includes paid AND open;
    * a re-run is idempotent (guarded by the agent marker) — counts do not double;
    * the CRM person + Support agent PII is VAULT-ROUTED at rest (vt_… token, no
      plaintext email in the column) — the masking-safe invariant the operator plane
      relies on.
  """
  use Driftwood.DataCase, async: false

  require Ash.Query

  alias Driftwood.Seeds

  setup do
    # The inherited-scope rows write the `company_role` / `lane` Tier-1 custom bag,
    # and the load board needs the pipeline stages. Both are seeded by the freight
    # scenario in dev; here we seed the pipeline directly + let demo_all define the
    # custom fields itself.
    org_id = Ecto.UUID.generate()
    :ok = Seeds.run(org_id)
    %{org_id: org_id}
  end

  defp count(resource, org_id) do
    actor = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}

    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.count!(actor: actor, authorize?: false)
  end

  test "demo_all populates every inherited scope and returns the org id", %{org_id: org_id} do
    assert Seeds.demo_all(org_id) == org_id

    # CRM
    assert count(Driftwood.Crm.Company, org_id) == 8
    assert count(Driftwood.Crm.Person, org_id) == 12
    assert count(Driftwood.Crm.Opportunity, org_id) == 6

    # Billing
    assert count(Driftwood.Billing.Customer, org_id) == 6
    assert count(Driftwood.Billing.Plan, org_id) == 3
    assert count(Driftwood.Billing.Price, org_id) == 3
    assert count(Driftwood.Billing.Subscription, org_id) == 6
    assert count(Driftwood.Billing.Invoice, org_id) == 12
    assert count(Driftwood.Billing.Payment, org_id) == 6

    # Support
    assert count(Driftwood.Support.Ticket, org_id) == 10
    assert count(Driftwood.Support.Agent, org_id) == 3
    assert count(Driftwood.Support.Conversation, org_id) == 4
    assert count(Driftwood.Support.Message, org_id) == 8
    assert count(Driftwood.Support.Sla, org_id) == 1
    assert count(Driftwood.Support.Macro, org_id) == 1
    assert count(Driftwood.Support.Csat, org_id) == 2
  end

  test "invoice mix includes paid AND open", %{org_id: org_id} do
    Seeds.demo_all(org_id)
    actor = %{org_id: org_id, role: :admin}

    statuses =
      Driftwood.Billing.Invoice
      |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(actor: actor, authorize?: false)
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    assert :paid in statuses
    assert :open in statuses
  end

  test "demo_all is idempotent — a re-run does not double-seed", %{org_id: org_id} do
    Seeds.demo_all(org_id)
    before = count(Driftwood.Crm.Company, org_id)

    # Re-run: the agent marker short-circuits, so counts stay put.
    assert Seeds.demo_all(org_id) == org_id
    assert count(Driftwood.Crm.Company, org_id) == before
    assert count(Driftwood.Support.Agent, org_id) == 3
  end

  test "seeded CRM person + Support agent PII is vault-routed at rest (masking-safe)", %{
    org_id: org_id
  } do
    Seeds.demo_all(org_id)

    # Read the RAW storage columns straight from Postgres — the masking-safe invariant
    # is that the plaintext email never sits in the column (a vt_… vault token does).
    %{rows: person_rows} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT fpr_emails::text FROM fpr_person WHERE fpr_org_id = $1",
        [Ecto.UUID.dump!(org_id)]
      )

    assert person_rows != []

    Enum.each(person_rows, fn [emails] ->
      assert emails =~ "vt_"
      refute emails =~ "@"
    end)

    %{rows: agent_rows} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT pii_fsa_email FROM fsa_agent WHERE fsa_org_id = $1",
        [Ecto.UUID.dump!(org_id)]
      )

    assert agent_rows != []

    Enum.each(agent_rows, fn [email_col] ->
      assert email_col =~ "vt_"
      refute email_col =~ "@"
    end)
  end
end
