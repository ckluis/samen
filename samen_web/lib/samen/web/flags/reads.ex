defmodule Samen.Web.Flags.Reads do
  @moduledoc """
  The framework FEATURE-FLAG read/write layer for the two-plane flag admin
  (WS-B B6; ADR-020; design G6 §3.5). Flags are Tier-0, org-scoped, NON-PII config
  rows (`pff`: name / enabled / rollout_pct / stage / target_rules / variants) —
  this surface introduces NO PII path.

  ## A3 read-bounding

  The list reads through `flags_page/3` built on `Samen.Web.Reads.page!/3` (BOUNDED
  BY CONSTRUCTION); every lookup read carries an explicit `limit(1)`.

  ## A3 write side (sanctioned domain actions only; kernel-enforced)

  Flag writes go through the blueprint's `:update` action, so the KERNEL runs the
  whole guarantee stack on every mutation: `OrgScope` (same-org confinement),
  `RoleAtLeast :admin` (config-row convention), and `Samen.FeatureFlags.NonPiiTargeting`
  (RP-F3 — a targeting rule keyed on a PII-classified attribute is REFUSED at the
  write boundary). This module adds NO policy of its own; the tenant-plane write path
  uses `write_scope/2`, the same-org PLANE-PRESERVING role elevation established by
  `Samen.Web.Billing.Reads.write_scope/2`.

  ## Write-through cache invalidation (the kill-switch mechanism, design §3.3)

  Every successful flag write calls `Samen.FeatureFlags.Cache.invalidate/1` for the
  flag's name — the write-through hop that makes a kill-switch flip (`enabled →
  false`) observable by the NEXT `evaluate/2` (bounded staleness = one hop; RP-F4
  proves the invalidate is load-bearing).
  """

  require Ash.Query

  alias Samen.FeatureFlags
  alias Samen.Web.Mount

  # The operator debugging fan-out (per-tenant evaluated state) — a bounded cohort,
  # not a hot list.
  @cohort_limit 50

  @doc """
  Read ONE keyset page of the org's feature flags — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`), built on `Samen.Web.Reads.page!/3`
  (BOUNDED BY CONSTRUCTION). Flags are non-PII config rows; sort/filter fields are
  bounded plain attributes. On any read error the page is EMPTY.
  """
  def flags_page(mount, scope, state) do
    Mount.resource(mount, FeatureFlag)
    |> Ash.Query.ensure_selected([:name, :description, :enabled, :rollout_pct, :stage, :target_rules, :variants])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :description])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc "Read ONE flag by id for `scope` (bounded lookup). `nil` when absent/denied."
  def get_flag(mount, scope, id) do
    Mount.resource(mount, FeatureFlag)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
  rescue
    _ -> nil
  end

  @doc """
  The tenant-ADMIN write scope for the kernel's admin-gated flag writes (`FeatureFlag`
  carries `RoleAtLeast :admin`; the mount's plane scope is a `:member`).

  Same-org role elevation ONLY — the `Samen.Web.Billing.Reads.write_scope/2` pattern:
  the elevation PRESERVES every plane marker from `Mount.scope/2`, so an
  operator-plane (impersonation) mount elevated here still carries `plane: :operator`
  and the kernel write guard behaves exactly as before — the elevation raises RBAC
  rank, never the masking plane. `OrgScope` still confines the write to `org_id`.
  """
  def write_scope(mount, org_id) do
    %Samen.Scope{actor: actor} = Mount.scope(mount, org_id)
    %Samen.Scope{actor: Map.put(actor, :role, :admin)}
  end

  @doc """
  Flip a flag's `enabled` gate through the sanctioned `:update` action (the tenant
  toggle AND the operator kill switch — `enabled → false` IS the kill switch,
  design §3.2 step 1). `{:ok, flag}` or `{:error, message}` (friendly). On success
  the cache entry is write-through invalidated.
  """
  def toggle_flag(mount, scope, id), do: update_flag(mount, scope, id, &%{enabled: !&1.enabled})

  @doc """
  Set a flag's `rollout_pct` ramp (clamped 0..100) through the sanctioned `:update`
  action. `{:ok, flag}` or `{:error, message}`. Invalidate-on-success.
  """
  def set_rollout(mount, scope, id, pct) when is_integer(pct) do
    update_flag(mount, scope, id, fn _ -> %{rollout_pct: pct |> max(0) |> min(100)} end)
  end

  @doc """
  Replace a flag's `target_rules` through the sanctioned `:update` action — the
  targeting-rule editor's write. The kernel `NonPiiTargeting` validation runs INSIDE
  the action (RP-F3): a rule keyed on a PII-classified attribute comes back
  `{:error, message}` with the refusal surfaced verbatim (the friendly validation
  error), and NOTHING persists. Invalidate-on-success.
  """
  def put_rules(mount, scope, id, rules) when is_list(rules) do
    update_flag(mount, scope, id, fn _ -> %{target_rules: rules} end)
  end

  @doc """
  The evaluated-state PREVIEW for a flag row (design §3.5 "evaluated state") — a
  `%Samen.FeatureFlags.Decision{}` via the kernel's cache-FREE `evaluate_config/4`:
  an admin page render never warms/poisons the shared ETS cache and never emits an
  assignment event. `subject` is the bounded non-PII scope (`%{org_id: ..., plan: ...}`).
  """
  def decision(flag, subject) do
    FeatureFlags.evaluate_config(flag.name, config_of(flag), subject)
  end

  @doc """
  The operator's TENANT COHORTS for the per-org evaluated-state debug view
  (design §3.5): the account `Org` rows in the OPERATOR namespace (`org_id ==
  operator_org_id, id != operator_org_id` — the same trusted non-PII grouping read
  as `Operator.Reads.accounts_page/3`, hence `authorize?: false` with the explicit
  filter). BOUNDED to #{@cohort_limit} rows; only bounded non-PII columns (name /
  plan) are selected — the targeting-subject keys, no PII path.
  """
  def tenant_cohorts(operator_mount, operator_org_id) do
    Mount.resource(operator_mount, Org)
    |> Ash.Query.ensure_selected([:name, :plan, :org_id])
    |> Ash.Query.filter(org_id == ^operator_org_id and id != ^operator_org_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@cohort_limit)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  # The plain config map `evaluate_config/4` expects, straight off the row (the same
  # shape `Cache.to_config/1` builds on the cached path).
  defp config_of(flag) do
    %{
      name: flag.name,
      enabled: flag.enabled,
      rollout_pct: flag.rollout_pct,
      stage: flag.stage,
      target_rules: flag.target_rules || [],
      variants: flag.variants || %{}
    }
  end

  # -- private write plumbing ---------------------------------------------------

  # Every mutation: bounded lookup → the sanctioned :update action (kernel policies +
  # NonPiiTargeting run) → write-through Cache.invalidate on success (design §3.3).
  defp update_flag(mount, scope, id, changes_fun) do
    case get_flag(mount, scope, id) do
      nil ->
        {:error, "Flag not found."}

      flag ->
        flag
        |> Ash.Changeset.for_update(:update, changes_fun.(flag), scope: scope)
        |> Ash.update()
        |> case do
          {:ok, updated} ->
            :ok = Samen.FeatureFlags.Cache.invalidate(updated.name)
            {:ok, updated}

          {:error, error} ->
            {:error, friendly_error(error)}
        end
    end
  rescue
    e -> {:error, friendly_error(e)}
  end

  @doc """
  A FRIENDLY, bounded message for a refused flag write. Surfaces the kernel
  validation's own message (e.g. the `NonPiiTargeting` refusal names the attribute
  and the governed allowlist) — framework/validation copy only, never a field value.
  """
  def friendly_error(error) do
    error
    |> flatten_errors()
    |> Enum.find_value(fn e ->
      case e do
        %{message: msg} when is_binary(msg) and msg != "" -> interpolate(msg, Map.get(e, :vars) || [])
        _ -> nil
      end
    end) || "Could not save this flag change."
  end

  defp flatten_errors(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten_errors/1)
  defp flatten_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten_errors/1)
  defp flatten_errors(error), do: [error]

  defp interpolate(msg, vars) do
    Enum.reduce(vars, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
