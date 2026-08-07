defmodule Samen.Fleet.Directive.Precedence do
  @moduledoc """
  J4 — the fleet flag PRECEDENCE engine (ADR-044 §7.3, T84b). Composes a
  `FleetDirective` flag entry over a product's OWN local flag config as a
  **one-way OFF authority**: any local off-state — kill, an explicit local deny
  rule matching the subject, or `rollout_pct: 0` — beats every fleet input, and
  no fleet directive can ever move a flag from off to on.

  ## Why this is a SEPARATE module, not an edit to `Samen.FeatureFlags`

  `Samen.FeatureFlags.evaluate/2`'s precedence pipeline (kill > deny > allow >
  targeting > rollout > default, ADR-020 §2) is the shipped, heavily-tested LOCAL
  engine — RP-F1/RP-F2/RP-F4 pin its determinism/fail-safe behaviour. ADR-044 §7.3
  layers a SECOND authority on top of it rather than reopening it:

      local_off?  =  local kill                       # enabled == false
                  OR local explicit deny matches
                  OR local rollout_pct <= 0           # feature_flags.ex:174-182 — an OFF state
                  OR local variant/gate resolves off  # a local "off" targeting rule matches

      if local_off?          -> OFF   (reason: :local_off)          # FLEET IS NOT CONSULTED
      else if fleet kill     -> OFF   (reason: :fleet_kill)
      else                   -> the ADR-020 ladder, with fleet rollout/variant/allow
                                layered UNDER local explicit deny and local targeting

  This is expressed as a PREDICATE, not a ranked list position, precisely because a
  ranked list is what hid the `rollout_pct: 0` case in this ADR's first draft
  (`Samen.FeatureFlags.eval_rollout/5` treats `rollout_pct <= 0` as an ordinary OFF
  state — `feature_flags.ex:174-182` — and a naive "fleet rollout ranks above local
  rollout" ladder would have silently RE-ENABLED a flag a local operator disabled
  during an incident).

  ## Two entry points

    * `decide/3` — the pure, subject-aware PREDICATE (what RP-J-8b asserts directly):
      given a local flag config, a fleet directive's flag entry, and a subject scope,
      returns the composed `%Samen.FeatureFlags.Decision{}`.
    * `merge_config/2` — the SUBJECT-INDEPENDENT config merge a host's
      `:fleet_directive_applier` seam (`Samen.Web.Fleet.Ingress.directive/2`, §7,
      `feature_flags: :fleet_directive_applier` app-env) can use to WRITE a new
      effective config into its own flag storage (e.g. via
      `Samen.Web.Flags.Reads.set_rollout/3` + `put_rules/3`) so that ORDINARY
      `Samen.FeatureFlags.evaluate/2` calls (no per-call fleet consultation) already
      reflect the fleet layer for every subsequent read — "fleet-supplied config
      lands in `Samen.FeatureFlags.Cache` as a distinct layer" (§7.3). Only the
      CONFIG-LEVEL local-off states (kill, `rollout_pct <= 0`) are safe to fold into
      an unconditional merge — a subject-scoped local deny/off rule is preserved
      correctly anyway because local's OWN rules are kept FIRST in the merged rule
      list (first-match-wins), so a per-subject local deny still shadows fleet's
      rules for exactly the subjects it targets, without needing per-subject writes.
  """

  alias Samen.FeatureFlags.{Decision, TargetRule}

  @typedoc "A plain local flag config map, the same shape `Samen.FeatureFlags.Cache` holds."
  @type local_config :: map()

  @typedoc "One `FleetDirective.flags[]` entry (ADR-044 §7.2), string- or atom-keyed."
  @type fleet_flag :: map()

  @doc """
  Is the LOCAL config's flag already in an OFF state, independent of fleet input?
  Four clauses, matched to the ADR's own predicate text — kill, an explicit local
  DENY rule matching `subject`, `rollout_pct <= 0` (a CONFIG-LEVEL off-state,
  independent of any subject's bucket), or a local targeting rule that resolves
  `then: "off"` for `subject`. `subject` is the same bounded non-PII scope
  `Samen.FeatureFlags.evaluate/2` takes (`%{org_id: ...}` at minimum).
  """
  @spec local_off?(local_config(), map()) :: boolean()
  def local_off?(local_config, subject) when is_map(local_config) and is_map(subject) do
    not truthy?(get(local_config, :enabled)) or
      rollout_pct(local_config) <= 0 or
      local_rule_off?(local_config, subject)
  end

  defp local_rule_off?(local_config, subject) do
    rules = TargetRule.parse(get(local_config, :target_rules))

    case TargetRule.first_match(rules, subject) do
      %TargetRule{then: :deny} -> true
      %TargetRule{then: :off} -> true
      _ -> false
    end
  end

  @doc """
  Does the fleet directive's flag entry carry a KILL? Accepts both string- and
  atom-keyed maps (a directive decoded off the wire is string-keyed JSON; a
  directive built in-process/in tests is often atom-keyed).
  """
  @spec fleet_kill?(fleet_flag()) :: boolean()
  def fleet_kill?(fleet_flag) when is_map(fleet_flag), do: truthy?(get(fleet_flag, :kill))

  @doc """
  The composed decision for ONE subject: `local_off?` first (fleet NOT consulted),
  then fleet kill, then the fleet layer UNDER local's own explicit deny/targeting
  (already excluded by `local_off?` returning `false`, so any local rule that
  matched here is a local ON/ALLOW/variant rule and still wins over fleet), then
  fleet's own targeting/rollout, then the LOCAL default gate.

  Reasons used: `:local_off`, `:fleet_kill`, `:allow`/`:targeted` (local rule win),
  `:fleet_allow`/`:fleet_targeted` (a fleet rule win), `:fleet_rollout_in`/
  `:fleet_rollout_out` (the fleet percentage bucket), `:default` (neither layer
  supplies an opinion — the local `enabled: true` gate stands).
  """
  @spec decide(local_config(), fleet_flag(), map()) :: Decision.t()
  def decide(local_config, fleet_flag, subject) when is_map(local_config) and is_map(subject) do
    cond do
      local_off?(local_config, subject) ->
        %Decision{on: false, reason: :local_off}

      fleet_kill?(fleet_flag) ->
        %Decision{on: false, reason: :fleet_kill}

      match = local_target_match(local_config, subject) ->
        TargetRule.decide(match)

      true ->
        fleet_layer_decision(fleet_flag, subject)
    end
  end

  defp local_target_match(local_config, subject) do
    local_config
    |> get(:target_rules)
    |> TargetRule.parse()
    |> Enum.reject(&(&1.then in [:deny, :off]))
    |> TargetRule.first_match(subject)
  end

  defp fleet_layer_decision(fleet_flag, subject) do
    fleet_rules = TargetRule.parse(get(fleet_flag, :rules))

    case TargetRule.first_match(fleet_rules, subject) do
      %TargetRule{then: :deny} ->
        %Decision{on: false, reason: :fleet_deny}

      %TargetRule{then: :allow} ->
        %Decision{on: true, reason: :fleet_allow}

      %TargetRule{} = match ->
        %{TargetRule.decide(match) | reason: fleet_reason(match)}

      nil ->
        fleet_rollout_decision(fleet_flag, subject)
    end
  end

  defp fleet_reason(%TargetRule{then: :off}), do: :fleet_targeted
  defp fleet_reason(_), do: :fleet_targeted

  defp fleet_rollout_decision(fleet_flag, subject) do
    rollout = rollout_pct(fleet_flag)

    cond do
      rollout <= 0 ->
        %Decision{on: false, reason: :default}

      rollout >= 100 ->
        %Decision{on: true, reason: :fleet_rollout_in}

      Samen.FeatureFlags.bucket(get(fleet_flag, :name) || "fleet", subject_key(subject)) < rollout ->
        %Decision{on: true, reason: :fleet_rollout_in}

      true ->
        %Decision{on: false, reason: :fleet_rollout_out}
    end
  end

  @doc """
  The SUBJECT-INDEPENDENT config merge (§7.3's "distinct layer"): local config
  UNCHANGED when the config-level local-off states hold (kill / `rollout_pct <=
  0` — the two off-states a merge can safely represent without per-subject data);
  `enabled: false` when the fleet flag carries `kill: true`; otherwise local's
  rollout_pct is REPLACED by the fleet's (fleet ADDS reach, never removes it — a
  fleet publish only ever used when local is not already off) and local's
  `target_rules` are kept FIRST with the fleet's rules APPENDED, so a local
  subject-scoped deny/off rule still wins first-match for the subjects it names.

  Returns `{tag, merged_config}` where `tag` is `:local_off | :fleet_kill |
  :fleet_applied` — the caller (e.g. a `:fleet_directive_applier` seam) decides
  whether/how to log or skip the write.
  """
  @spec merge_config(local_config(), fleet_flag()) :: {:local_off | :fleet_kill | :fleet_applied, local_config()}
  def merge_config(local_config, fleet_flag) when is_map(local_config) and is_map(fleet_flag) do
    cond do
      config_level_local_off?(local_config) ->
        {:local_off, local_config}

      fleet_kill?(fleet_flag) ->
        {:fleet_kill, put(local_config, :enabled, false)}

      true ->
        merged =
          local_config
          |> put(:rollout_pct, get(fleet_flag, :rollout_pct) || rollout_pct(local_config))
          |> put(:target_rules, local_rules_list(local_config) ++ fleet_rules_wire(fleet_flag))

        {:fleet_applied, merged}
    end
  end

  # The SUBJECT-INDEPENDENT half of local_off? — the two clauses `merge_config/2`
  # can honor without per-subject data. A subject-scoped local deny/off rule is
  # NOT evaluated here (it cannot be, config-level) — it is preserved correctly
  # anyway by keeping local's rules first in the merge (see moduledoc).
  defp config_level_local_off?(local_config), do: not truthy?(get(local_config, :enabled)) or rollout_pct(local_config) <= 0

  defp local_rules_list(local_config), do: get(local_config, :target_rules) || []
  defp fleet_rules_wire(fleet_flag), do: get(fleet_flag, :rules) || []

  # ---------------------------------------------------------------------------
  # Config coercion (mirrors Samen.FeatureFlags' own tolerant reads — string OR
  # atom keys, since a directive fresh off JSON is string-keyed while an
  # in-process/test-built one is often atom-keyed).
  # ---------------------------------------------------------------------------

  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp rollout_pct(config) do
    case get(config, :rollout_pct) do
      n when is_integer(n) -> clamp(n)
      n when is_float(n) -> clamp(trunc(n))
      _ -> 0
    end
  end

  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 100, do: 100
  defp clamp(n), do: n

  defp subject_key(%{subject_key: key}) when not is_nil(key), do: to_string(key)
  defp subject_key(%{"subject_key" => key}) when not is_nil(key), do: to_string(key)
  defp subject_key(%{org_id: org_id}) when not is_nil(org_id), do: to_string(org_id)
  defp subject_key(%{"org_id" => org_id}) when not is_nil(org_id), do: to_string(org_id)
  defp subject_key(_), do: ""
end
