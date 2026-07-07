defmodule Samen.OperatorPlane do
  @moduledoc """
  The operator plane, built FROM THE SAME scope objects (T4.1 clause (a); doc §control
  "Running the business" lead).

  > The product your tenants use and the control plane you run the business with are the
  > same objects on the same substrate — an operator CRM where accounts are tenant orgs,
  > ticketing for their support, billing rolled up across tenants.

  The operator plane does NOT define new resources — it READS the existing universal
  scopes (Identity, Billing, Support) through a distinct operator actor
  (`Samen.OperatorPlane.Actor`), keyed by ONE target org at a time.

  ## Single-org paths only (T4.1 scope boundary)

  This module keeps to the **single-org** operator paths (T4.1). Cross-tenant AGGREGATE
  reads (MRR across all tenants, queue depth across tenants, the token-blind aggregate
  actor) are T4.2 — deliberately NOT here. Every function takes ONE `org_id` and reads
  that org's rows.

  ## Host wiring (samen_core is host-agnostic)

  samen_core does not know the host's resource module names (`Demo.Identity.Org`,
  `Demo.BillingScope.Subscription`, …). The host passes them in a config map:

      config :samen_core, :operator_plane,
        org: Demo.Identity.Org,
        subscription: Demo.BillingScope.Subscription,
        plan: Demo.BillingScope.Plan,
        ticket: Demo.SupportScope.Ticket

  ...or passes a `:resources` keyword to each function (injectable for tests). A missing
  resource makes that section of the view empty (fail closed — never crash the operator
  console because a scope isn't mounted).

  ## Why `authorize?: false` scoped to one org (not a tenant member scope)

  An operator actor is NOT a tenant member, so it has no `%Samen.Scope{}` org boundary
  of its own — it reaches a specific org through the operator plane. Each read here
  filters `org_id == ^org_id` EXPLICITLY and reads with `authorize?: false` at the
  operator plane (the operator's own RBAC — `may_read_operator_crm?/1` — is the gate,
  checked BEFORE the read). This is the operator-plane counterpart of the tenant
  org-scope FilterCheck: the operator sees exactly ONE org's rows per call.

  PII stays MASKED here too: the reads return the rows with `%Masked{}` vaulted fields
  (no reveal grant is involved). The operator CRM account view carries only non-PII
  facts about the tenant ORG (its name, plan, subscription status, ticket counts) —
  never the tenant's CUSTOMERS' PII. To see a tenant's customer data with masking, the
  operator opens an IMPERSONATION session (`Samen.Impersonation`).
  """

  require Ash.Query

  alias Samen.OperatorPlane.Actor

  @doc """
  The operator RBAC gate for reading the operator CRM. `:operator_admin`,
  `:operator_support`, and `:operator_readonly` may all read it; a non-operator actor
  may NOT.
  """
  @spec may_read_operator_crm?(Actor.t() | term()) :: boolean()
  def may_read_operator_crm?(%Actor{operator_role: role}),
    do: role in [:operator_admin, :operator_support, :operator_readonly]

  def may_read_operator_crm?(_), do: false

  @doc """
  The operator CRM ACCOUNT view for ONE tenant org (accounts ARE tenant orgs) — an
  Identity org joined to its Billing subscription (+ plan) and a Support ticket rollup.

  Returns `{:ok, account}` where `account` is a plain map:

      %{
        org_id:        "…",
        org_name:      "Acme",           # non-PII org name
        subscription:  %{status: :active, plan: "Pro", ...} | nil,
        open_tickets:  3,                # single-org ticket count (a rollup read)
        total_tickets: 12
      }

  Refuses `{:error, :not_authorized}` if the operator may not read the operator CRM.

  Options:
    * `:resources` — override the host resource map (for tests).
    * `:repo` — the repo (defaults to each resource's own AshPostgres repo).
  """
  @spec account(Actor.t() | term(), binary(), keyword()) :: {:ok, map()} | {:error, term}
  def account(operator, org_id, opts \\ []) do
    if may_read_operator_crm?(operator) do
      res = resources(opts)

      org = read_org(res[:org], org_id)

      account = %{
        org_id: org_id,
        org_name: org && Map.get(org, :name),
        subscription: read_subscription(res, org_id),
        open_tickets: count_tickets(res[:ticket], org_id, status: :open),
        total_tickets: count_tickets(res[:ticket], org_id, status: :any)
      }

      {:ok, account}
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Operator ticketing over ONE tenant org's Support tickets (single-org). Returns
  `{:ok, tickets}` — a list of the org's ticket rows (subject/status/priority — no PII;
  a ticket subject line is operator-visible metadata, and any vaulted message body is
  reached only through impersonation + reveal). Refuses if unauthorized.
  """
  @spec tickets(Actor.t() | term(), binary(), keyword()) :: {:ok, [map()]} | {:error, term}
  def tickets(operator, org_id, opts \\ []) do
    if may_read_operator_crm?(operator) do
      res = resources(opts)
      {:ok, read_tickets(res[:ticket], org_id)}
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Single-org billing summary — the subscription + plan for ONE tenant org (the
  single-org billing path; cross-tenant MRR rollups are T4.2). Refuses if unauthorized.
  """
  @spec billing(Actor.t() | term(), binary(), keyword()) :: {:ok, map() | nil} | {:error, term}
  def billing(operator, org_id, opts \\ []) do
    if may_read_operator_crm?(operator) do
      res = resources(opts)
      {:ok, read_subscription(res, org_id)}
    else
      {:error, :not_authorized}
    end
  end

  # ==========================================================================
  # Internal reads (single-org, authorize?: false at the operator plane, explicit
  # org filter — the operator-plane counterpart of the tenant org-scope FilterCheck).
  # ==========================================================================

  defp resources(opts) do
    Keyword.get(opts, :resources) ||
      Application.get_env(:samen_core, :operator_plane, [])
      |> Enum.into(%{})
  end

  defp read_org(nil, _org_id), do: nil

  defp read_org(org_res, org_id) do
    case safe_get(org_res, org_id) do
      %{} = org -> org
      _ -> nil
    end
  end

  defp read_subscription(res, org_id) do
    sub_res = res[:subscription]
    plan_res = res[:plan]

    with mod when not is_nil(mod) <- sub_res,
         [sub | _] <- safe_read_by_org(sub_res, org_id) do
      plan_name =
        with pmod when not is_nil(pmod) <- plan_res,
             plan_id when not is_nil(plan_id) <- Map.get(sub, :plan_id),
             %{} = plan <- safe_get(plan_res, plan_id) do
          Map.get(plan, :name)
        else
          _ -> nil
        end

      %{
        subscription_id: Map.get(sub, :id),
        status: Map.get(sub, :status),
        plan: plan_name,
        current_period_end: Map.get(sub, :current_period_end)
      }
    else
      _ -> nil
    end
  end

  defp count_tickets(nil, _org_id, _opts), do: 0

  defp count_tickets(ticket_res, org_id, opts) do
    status = Keyword.get(opts, :status, :any)

    ticket_res
    |> safe_read_by_org(org_id)
    |> Enum.filter(fn t ->
      status == :any or Map.get(t, :status) == status
    end)
    |> length()
  end

  defp read_tickets(nil, _org_id), do: []

  defp read_tickets(ticket_res, org_id) do
    ticket_res
    |> safe_read_by_org(org_id)
    |> Enum.map(fn t ->
      %{
        id: Map.get(t, :id),
        subject: Map.get(t, :subject),
        status: Map.get(t, :status),
        priority: Map.get(t, :priority)
      }
    end)
  end

  # Read all of a resource's rows for ONE org, at the operator plane. `authorize?: false`
  # (the operator RBAC gate ran before the read), explicit org filter (single-org).
  # Callers guard nil before reaching here.
  defp safe_read_by_org(resource, org_id) do
    try do
      resource
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)
    rescue
      _ -> []
    end
  end

  # Callers guard nil before reaching here.
  defp safe_get(resource, id) do
    try do
      Ash.get!(resource, id, authorize?: false)
    rescue
      _ -> nil
    end
  end
end
