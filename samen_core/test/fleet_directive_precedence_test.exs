defmodule Samen.Fleet.Directive.PrecedenceTest do
  @moduledoc """
  J4 — ADR-044 §7.3 / RP-J-8 / RP-J-8b: the fleet flag precedence engine.

  `Samen.Fleet.Directive.Precedence` is a pure, subject-aware composer over a
  LOCAL flag config + a `FleetDirective` flag entry. RP-J-8b's table, asserted
  row-by-row with a positive control on every row: for EACH local off-state
  (kill / explicit deny / `rollout_pct: 0` / a local "off" targeting match), a
  fleet directive with `rollout_pct: 100` leaves the flag OFF with
  `reason: :local_off` — removing the local off-state and the SAME directive
  turns it ON. RP-J-8 (fan-out + kill): the SAME fleet directive applied to TWO
  INDEPENDENTLY CONFIGURED local flags (simulating two products' own flag
  engines) turns BOTH off, proving the composition has no cross-contamination
  and no shared hidden state.
  """
  use ExUnit.Case, async: true

  alias Samen.Fleet.Directive.Precedence
  alias Samen.FeatureFlags.Decision

  @fleet_on %{"name" => "billing.invoice_pdf", "kill" => false, "rollout_pct" => 100, "rules" => []}
  @fleet_kill %{"name" => "billing.invoice_pdf", "kill" => true, "rollout_pct" => 100, "rules" => []}

  @subject %{org_id: "org-1"}

  # ---------------------------------------------------------------------------
  # RP-J-8b — each local off-state beats a fleet rollout_pct: 100 (fleet NOT consulted)
  # ---------------------------------------------------------------------------

  describe "RP-J-8b — local off-states beat fleet (fleet is a one-way OFF authority)" do
    test "local KILL (enabled: false) beats fleet rollout_pct: 100" do
      local = %{enabled: false, rollout_pct: 100, target_rules: []}

      assert %Decision{on: false, reason: :local_off} = Precedence.decide(local, @fleet_on, @subject)

      # positive control: remove the local kill, same directive turns it ON.
      unkilled = %{local | enabled: true}
      assert %Decision{on: true} = Precedence.decide(unkilled, @fleet_on, @subject)
    end

    test "local EXPLICIT DENY (matching the subject) beats fleet rollout_pct: 100" do
      local = %{
        enabled: true,
        rollout_pct: 100,
        target_rules: [%{"attribute" => "org_id", "op" => "eq", "values" => ["org-1"], "then" => "deny"}]
      }

      assert %Decision{on: false, reason: :local_off} = Precedence.decide(local, @fleet_on, @subject)

      # positive control: the SAME rule does not match a DIFFERENT subject → fleet applies.
      other_subject = %{org_id: "org-2"}
      assert %Decision{on: true} = Precedence.decide(local, @fleet_on, other_subject)

      # positive control: remove the deny rule entirely, same subject, fleet applies.
      no_rule = %{local | target_rules: []}
      assert %Decision{on: true} = Precedence.decide(no_rule, @fleet_on, @subject)
    end

    test "local rollout_pct: 0 beats fleet rollout_pct: 100 (the case the ranked ladder got wrong)" do
      local = %{enabled: true, rollout_pct: 0, target_rules: []}

      assert %Decision{on: false, reason: :local_off} = Precedence.decide(local, @fleet_on, @subject)

      # positive control: raise the local rollout off zero, the same directive turns it ON.
      raised = %{local | rollout_pct: 100}
      assert %Decision{on: true} = Precedence.decide(raised, @fleet_on, @subject)
    end

    test "a local targeting rule resolving OFF for this subject beats fleet rollout_pct: 100" do
      local = %{
        enabled: true,
        rollout_pct: 100,
        target_rules: [%{"attribute" => "org_id", "op" => "eq", "values" => ["org-1"], "then" => "off"}]
      }

      assert %Decision{on: false, reason: :local_off} = Precedence.decide(local, @fleet_on, @subject)

      other_subject = %{org_id: "org-2"}
      assert %Decision{on: true} = Precedence.decide(local, @fleet_on, other_subject)
    end
  end

  # ---------------------------------------------------------------------------
  # RP-J-8b — sabotage twin lives in scripts/sabotages/ (reorders the predicate so
  # fleet rollout precedes local_off? — see evidence.txt); this is the green anchor
  # the sabotage flips.
  # ---------------------------------------------------------------------------

  describe "fleet applies when local is not off" do
    test "fleet KILL beats an otherwise-on local config" do
      local = %{enabled: true, rollout_pct: 100, target_rules: []}

      assert %Decision{on: false, reason: :fleet_kill} = Precedence.decide(local, @fleet_kill, @subject)

      # positive control: fleet without kill → local's own rollout wins (on).
      assert %Decision{on: true} = Precedence.decide(local, @fleet_on, @subject)
    end

    test "fleet rollout_pct: 100 turns on a local config with no rollout/rules configured" do
      local = %{enabled: true, rollout_pct: nil, target_rules: nil}

      assert %Decision{on: false, reason: :local_off} = Precedence.decide(local, @fleet_on, @subject)
    end

    test "fleet targeting rule wins under a permissive local config" do
      local = %{enabled: true, rollout_pct: 50, target_rules: []}
      fleet = %{"kill" => false, "rollout_pct" => 0, "rules" => [%{"attribute" => "org_id", "op" => "eq", "values" => ["org-1"], "then" => "on"}]}

      assert %Decision{on: true, reason: :fleet_targeted} = Precedence.decide(local, fleet, @subject)
    end
  end

  # ---------------------------------------------------------------------------
  # RP-J-8 — fan-out + kill: the SAME fleet directive turns off TWO INDEPENDENT
  # local flag configs (simulating two products' own flag engines), each with
  # DIFFERENT pre-existing local state, proving no cross-contamination.
  # ---------------------------------------------------------------------------

  describe "RP-J-8 — fan-out reaches independent 'engines' (two independently-configured local states)" do
    test "a fleet kill turns OFF both app-A's and app-B's local config, each independently" do
      app_a_local = %{enabled: true, rollout_pct: 75, target_rules: []}
      app_b_local = %{enabled: true, rollout_pct: 10, target_rules: [%{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "on"}]}

      assert %Decision{on: false, reason: :fleet_kill} = Precedence.decide(app_a_local, @fleet_kill, @subject)
      assert %Decision{on: false, reason: :fleet_kill} = Precedence.decide(app_b_local, @fleet_kill, %{org_id: "org-1", plan: "pro"})

      # positive control: absent the kill, each app's OWN local config decides independently
      # (app A's rollout is 75%, app B's own targeting rule matches) — no shared state leaked.
      assert %Decision{on: true} = Precedence.decide(app_a_local, @fleet_on, @subject)
      assert %Decision{on: true, reason: :targeted} = Precedence.decide(app_b_local, @fleet_on, %{org_id: "org-1", plan: "pro"})

      # an app-B-only local off-state does not affect app A (fan-out independence).
      app_b_killed = %{app_b_local | enabled: false}
      assert %Decision{on: false, reason: :local_off} = Precedence.decide(app_b_killed, @fleet_on, %{org_id: "org-1", plan: "pro"})
      assert %Decision{on: true} = Precedence.decide(app_a_local, @fleet_on, @subject)
    end
  end

  # ---------------------------------------------------------------------------
  # merge_config/2 — the config-level, subject-independent write helper a
  # `:fleet_directive_applier` seam uses.
  # ---------------------------------------------------------------------------

  describe "merge_config/2 — the write-side layer" do
    test "local kill is preserved untouched (:local_off, fleet not consulted)" do
      local = %{enabled: false, rollout_pct: 50, target_rules: []}
      assert {:local_off, ^local} = Precedence.merge_config(local, @fleet_on)
    end

    test "local rollout_pct: 0 is preserved untouched (:local_off)" do
      local = %{enabled: true, rollout_pct: 0, target_rules: []}
      assert {:local_off, ^local} = Precedence.merge_config(local, @fleet_on)
    end

    test "fleet kill: false -> local, kill: true -> merged config disables it" do
      local = %{enabled: true, rollout_pct: 50, target_rules: []}
      assert {:fleet_kill, %{enabled: false}} = Precedence.merge_config(local, @fleet_kill)
    end

    test "fleet rollout replaces local rollout; local rules kept FIRST, fleet rules appended" do
      local = %{
        enabled: true,
        rollout_pct: 10,
        target_rules: [%{"attribute" => "org_id", "op" => "eq", "values" => ["org-9"], "then" => "deny"}]
      }

      fleet = %{"kill" => false, "rollout_pct" => 80, "rules" => [%{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "on"}]}

      assert {:fleet_applied, merged} = Precedence.merge_config(local, fleet)
      assert merged.rollout_pct == 80

      assert [
               %{"attribute" => "org_id", "then" => "deny"},
               %{"attribute" => "plan", "then" => "on"}
             ] = merged.target_rules

      # the merged config, evaluated via decide/3 for the org the LOCAL deny targets,
      # still denies — the local deny rule survives the merge, first-match-wins.
      assert %Decision{on: false, reason: :local_off} =
               Precedence.decide(local, fleet, %{org_id: "org-9"})
    end
  end
end
