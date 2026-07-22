defmodule Samen.Web.Onboarding do
  @moduledoc """
  The framework ONBOARDING-WIZARD ENGINE (ADR-035 §5 A8; spec §WS-A A8; T08) —
  org naming, the plan-selection HOOK (honest empty state until WS-B wires
  real billing), and completion tracking. `Samen.Web.Onboarding.WizardLive`
  is the one UI consumer; every generated app inherits this seam (A9 wires
  the `samen_onboarding_routes` macro at ≈0 authored LOC).

  The teammate-invite step is NOT reimplemented here — it wraps T05's
  confirmed `Samen.Identity.Invite` flow via `Samen.Web.Settings.Invitations`
  (the SAME engine `Samen.Web.Settings.InvitationsLive` calls), so invite
  creation, the rank-ceiling policy, and the audit/notification taxonomy are
  exercised exactly once, in one place.

  ## Completion — the "never re-trap" contract

  `Org.onboarded_at` (Tier-0 config; `nil` until `complete!/3` runs) is the
  ONE source of truth `needed?/3` reads. There is no session/client flag: a
  host that mounts the wizard twice, or a user who revisits `/onboarding`
  after finishing, gets the SAME answer both times because it is read off
  the org row, not reconstructed from navigation state.

  ## Plan-selection HOOK (fail-honest — INV-4 spirit)

  `plan_choices/2` resolves `Mount.label(mount, :plan_labels, nil)` — an
  OPTIONAL `{mod, fun, args}` a host wires once WS-B billing exists. Absent,
  erroring, or an empty return is `:not_configured`: the wizard renders the
  HONEST "no plans configured" empty state. This module never fabricates a
  plan list — the exact same discipline `Samen.Delivery.Smtp`/
  `Samen.Files.Storage.S3` apply to an unconfigured adapter (house
  CLAUDE.md: "a stub that claims success is the exact lie the gates
  sabotage-test for").

  ## No PII / no masking surface

  `Org` carries no vault-routed field (`name`/`plan`/`onboarded_at` are all
  plain columns per the ADR-035 blueprint — "Org — the tenant anchor... No
  PII"). This module never calls `Samen.Vault.reveal/3` and has no
  `%Samen.Masked{}` branch; it owes no `Samen.MaskingCase` proof.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @type mods :: %{required(:org) => module(), required(:repo) => module()}

  @doc "Build the org read/write mods map for `mount`."
  @spec mods(Mount.t()) :: mods()
  def mods(%Mount{} = mount), do: %{org: Mount.resource(mount, Org), repo: mount.repo}

  @doc """
  Read a single `Org` by id for `scope` — `{:ok, org}` or `{:error,
  :not_found}` (unknown id, cross-org id under `OrgIsSelf`, or any read
  error — one outcome, no existence oracle, never raises).
  """
  @spec org(Mount.t(), Samen.Scope.t() | map(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def org(%Mount{} = mount, scope, org_id) when is_binary(org_id) do
    Mount.resource(mount, Org)
    |> Ash.Query.ensure_selected([:id, :name, :plan, :onboarded_at])
    |> Ash.Query.filter(id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> case do
      [org | _] -> {:ok, org}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def org(_mount, _scope, _org_id), do: {:error, :not_found}

  @doc """
  TRUE while the wizard should be OFFERED for `org_id` (`onboarded_at` is
  `nil`); `FALSE` once `complete!/3` has run — the "never re-trap" contract.
  A `nil` org id, a missing/cross-org org, or any read error fails toward
  "not needed" (fail SAFE: no wizard resurrected on a read hiccup — mirrors
  `Samen.Web.FirstRun`'s fail-safe-false posture for its own probe).
  """
  @spec needed?(Mount.t(), Samen.Scope.t() | map(), String.t() | nil) :: boolean()
  def needed?(_mount, _scope, nil), do: false

  def needed?(%Mount{} = mount, scope, org_id) when is_binary(org_id) do
    case org(mount, scope, org_id) do
      {:ok, %{onboarded_at: nil}} -> true
      _ -> false
    end
  end

  @doc """
  Step 1 — org naming: write `Org.name`. `{:ok, org}` / `{:error, reason}`
  (a blank name is refused by the resource's own `allow_nil?: false`
  constraint — the same validation every other org-name write gets).
  """
  @spec name_org(Mount.t(), Samen.Scope.t() | map(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def name_org(%Mount{} = mount, scope, org_id, name) when is_binary(org_id) and is_binary(name) do
    with {:ok, org} <- org(mount, scope, org_id) do
      org
      |> Ash.Changeset.for_update(:update, %{name: name}, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  @doc "The exact fail-honest copy the plan-selection empty state renders (INV-4 — asserted verbatim by the wizard test, never paraphrased)."
  @spec no_plans_copy() :: String.t()
  def no_plans_copy, do: "No plans configured yet — billing is not set up for this workspace."

  @doc """
  Step 2 — the plan-selection HOOK. `{:ok, [%{key:, label:}, ...]}` when the
  host wired `Mount.label(mount, :plan_labels, {mod, fun, args})` (called as
  `apply(mod, fun, args ++ [org_id])`, expected to return a non-empty list
  of `%{key:, label:}` maps or `{key, label}` pairs) — else `:not_configured`
  (absent label, a raise, or an empty/malformed return all fold to the SAME
  honest "unwired" outcome; never a partially-fake list).
  """
  @spec plan_choices(Mount.t(), String.t() | nil) ::
          {:ok, [%{key: String.t(), label: String.t()}]} | :not_configured
  def plan_choices(%Mount{} = mount, org_id) do
    case Mount.label(mount, :plan_labels, nil) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        case apply(mod, fun, args ++ [org_id]) |> normalize_plans() do
          [_ | _] = choices -> {:ok, choices}
          [] -> :not_configured
        end

      _ ->
        :not_configured
    end
  rescue
    _ -> :not_configured
  end

  defp normalize_plans(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{key: k, label: l} when is_binary(k) and is_binary(l) -> [%{key: k, label: l}]
      {k, l} when is_binary(k) and is_binary(l) -> [%{key: k, label: l}]
      _ -> []
    end)
  end

  defp normalize_plans(_), do: []

  @doc """
  Step 2 write — set `Org.plan` to `plan_key`, but ONLY when `plan_key` is
  one of `plan_choices/2`'s CURRENT offerings (the hook is the single source
  of truth for what a plan even is — never an actor-forged value).
  `{:error, :invalid_plan}` when the hook is unconfigured or `plan_key`
  isn't currently offered; otherwise `{:ok, org}` / `{:error, reason}`.
  """
  @spec select_plan(Mount.t(), Samen.Scope.t() | map(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def select_plan(%Mount{} = mount, scope, org_id, plan_key) when is_binary(org_id) and is_binary(plan_key) do
    case plan_choices(mount, org_id) do
      {:ok, choices} ->
        if Enum.any?(choices, &(&1.key == plan_key)) do
          with {:ok, org} <- org(mount, scope, org_id) do
            org
            |> Ash.Changeset.for_update(:update, %{plan: plan_key}, scope: scope)
            |> Ash.update(scope: scope)
          end
        else
          {:error, :invalid_plan}
        end

      :not_configured ->
        {:error, :invalid_plan}
    end
  end

  @doc """
  Completion — sets `Org.onboarded_at` (the Tier-0 setting `needed?/3`
  reads). Idempotent: calling it again on an already-onboarded org is a
  harmless no-op write (the timestamp simply advances), never an error.
  `{:ok, org}` / `{:error, reason}`.
  """
  @spec complete!(Mount.t(), Samen.Scope.t() | map(), String.t()) :: {:ok, term()} | {:error, term()}
  def complete!(%Mount{} = mount, scope, org_id) when is_binary(org_id) do
    with {:ok, org} <- org(mount, scope, org_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      org
      |> Ash.Changeset.for_update(:update, %{}, scope: scope)
      |> Ash.Changeset.force_change_attribute(:onboarded_at, now)
      |> Ash.update(scope: scope)
    end
  end
end
