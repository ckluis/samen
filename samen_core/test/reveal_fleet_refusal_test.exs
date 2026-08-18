defmodule Samen.RevealFleetRefusalTest do
  @moduledoc """
  Carried-LOW 1 (T82) — RP-J-6's structural half. ADR §4.6 lists `Samen.Reveal.reveal/5`
  among STRUCTURAL refusals for a fleet actor, but before this task the refusal was
  only grant-mediated (`Samen.Reveal.DenyAll`'s default deny) — a tautology, since a
  PERMISSIVE grant checker would have let a fleet actor through. This suite runs
  RP-J-6 with a permissive grant checker so the structural `cond` clause added to
  `Samen.Reveal.reveal/5` is what actually proves the refusal, not a coincidence of
  the default grant model.
  """
  use ExUnit.Case, async: true

  alias Samen.Fleet.{AdminActor, HeartbeatActor}

  defmodule PermissiveGrant do
    @moduledoc "A grant checker that approves EVERYTHING — the anti-tautology instrument."
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_context), do: true
  end

  # A minimal fake resource declaring a reveal action, so the marker gate passes
  # and the ONLY thing standing between the actor and Samen.Vault.reveal/3 is the
  # aggregate/fleet structural clauses + the (permissive) grant.
  defmodule FakeRevealResource do
    def spark_dsl_config, do: %{}
  end

  # `FakeRevealResource` has NO declared reveal action at all — deliberately, to
  # prove the fleet-actor `cond` clause fires BEFORE the marker gate (which would
  # otherwise deny with `:not_reveal_action` and mask what we are testing).

  describe "RP-J-6 — structural refusal, permissive grant checker" do
    test "a heartbeat actor is refused even when the grant checker is fully permissive" do
      actor = HeartbeatActor.new("app-1")

      assert {:error, :fleet_actor_denied} =
               Samen.Reveal.reveal(actor, %Samen.Masked{label: :x, token: "vt_x"}, :reveal_x,
                 FakeRevealResource,
                 grant: PermissiveGrant,
                 repo: nil
               )
    end

    test "a fleet-admin actor is refused even when the grant checker is fully permissive" do
      actor = AdminActor.new("operator-1")

      assert {:error, :fleet_actor_denied} =
               Samen.Reveal.reveal(actor, %Samen.Masked{label: :x, token: "vt_x"}, :reveal_x,
                 FakeRevealResource,
                 grant: PermissiveGrant,
                 repo: nil
               )
    end

    test "the refusal precedes the marker gate (a non-reveal action still denies as fleet_actor_denied, not not_reveal_action)" do
      actor = HeartbeatActor.new("app-1")

      assert {:error, :fleet_actor_denied} =
               Samen.Reveal.reveal(actor, %Samen.Masked{label: :x, token: "vt_x"}, :not_a_real_action,
                 FakeRevealResource,
                 grant: PermissiveGrant,
                 repo: nil
               )
    end

    test "POSITIVE CONTROL — the aggregate actor is still refused too (unchanged sibling clause)" do
      actor = Samen.Aggregate.Actor.new()

      assert {:error, :aggregate_actor_denied} =
               Samen.Reveal.reveal(actor, %Samen.Masked{label: :x, token: "vt_x"}, :reveal_x,
                 FakeRevealResource,
                 grant: PermissiveGrant,
                 repo: nil
               )
    end
  end

  describe "structural probe — no Samen.Fleet.* module references Impersonation/Reveal/PiiResolution as a CONSUMER" do
    test "Samen.Fleet.* source never calls into Samen.Impersonation/PiiResolution (§6.4(c) shape, T83 owns the full RP-J-6(b/c) probe)" do
      fleet_files = Path.wildcard(Path.join(File.cwd!(), "lib/samen/fleet/**/*.ex"))

      refute Enum.empty?(fleet_files), "expected to find Samen.Fleet.* source files"

      offenders =
        for file <- fleet_files,
            contents = File.read!(file),
            String.contains?(contents, "Samen.Impersonation.") or
              String.contains?(contents, "Samen.Api.PiiResolution") do
          file
        end

      assert offenders == [],
             "Samen.Fleet.* must never consume Samen.Impersonation/PiiResolution: #{inspect(offenders)}"
    end
  end
end
