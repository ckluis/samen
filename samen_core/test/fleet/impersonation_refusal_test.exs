defmodule Samen.Fleet.ImpersonationRefusalTest do
  @moduledoc """
  T83 / J3 — RP-J-6: masked impersonation stays per-product, and NO cross-product session or
  reveal can carry PII across products (ADR-044 §6.4, §16.1; INV-1/INV-2).

  The J3 identity change adds cross-product AUTHORIZATION expression only; it introduces NO
  cross-product impersonation session and NO fleet-wide reveal grant. This suite proves the
  claim holds BY CONSTRUCTION, not by care:

    * a fleet credential's actor (`Samen.Fleet.HeartbeatActor`) and the fleet-admin actor
      (`Samen.Fleet.AdminActor`) are structurally refused by `Samen.Impersonation.open/3`
      (`Actor.may_impersonate?/1` is false — they are not `%Samen.OperatorPlane.Actor{}`);
    * the same actors are structurally refused by `Samen.Reveal.reveal/5` (pinned separately by
      `reveal_fleet_refusal_test.exs` with a PERMISSIVE grant checker);
    * a REAL operator actor is the positive control — it passes `may_impersonate?/1`, so the
      refusals above are not a tautology (the gate genuinely admits an entitled principal).

  There is NO cross-product session concept for these actors to exploit: `imp_impersonation_session`
  rows live in each PRODUCT's DB keyed `{operator_id, org_id}`; the fleet has no table for them.
  So a fleet principal cannot open a session anywhere, and cannot reveal a single vault-routed
  field — the only ways PII would move, and both are closed.
  """
  use ExUnit.Case, async: true

  alias Samen.Fleet.{AdminActor, HeartbeatActor}
  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor

  describe "fleet actors cannot open an impersonation session (INV-1: no cross-product session)" do
    test "the heartbeat actor is refused by Impersonation.open/3" do
      assert {:error, :not_authorized} =
               Impersonation.open(HeartbeatActor.new("app-1"), "org-1", "probe")
    end

    test "the fleet-admin actor is refused by Impersonation.open/3" do
      assert {:error, :not_authorized} =
               Impersonation.open(AdminActor.new("op-1"), "org-1", "probe")
    end

    test "a bare fleet-shaped map (defense in depth) is refused" do
      assert {:error, :not_authorized} =
               Impersonation.open(%{kind: :fleet_heartbeat, app_id: "app-1"}, "org-1", "probe")
    end
  end

  describe "may_impersonate?/1 — the gate the refusals ride, with a positive control" do
    test "fleet actors are NOT impersonation-capable" do
      refute Actor.may_impersonate?(HeartbeatActor.new("app-1"))
      refute Actor.may_impersonate?(AdminActor.new("op-1"))
    end

    test "CONTROL — a real operator actor IS impersonation-capable (the refusals are not a tautology)" do
      # A genuine operator passes the gate `open/3` branches on — proving the fleet-actor
      # denials above deny something the gate would otherwise admit.
      assert Actor.may_impersonate?(Actor.new("op-1", :operator_admin))
      assert Actor.may_impersonate?(Actor.new("op-2", :operator_support))
    end
  end

  describe "fleet actors cannot reveal a vaulted field (INV-2: no cross-product PII read)" do
    test "the heartbeat actor is refused by Reveal.reveal/5, structurally" do
      # Structural refusal (T82 carried-LOW 1), re-asserted here as the J3 no-cross-product-PII
      # probe. The exhaustive permissive-grant proof lives in reveal_fleet_refusal_test.exs.
      assert {:error, :fleet_actor_denied} =
               Samen.Reveal.reveal(
                 HeartbeatActor.new("app-1"),
                 %Samen.Masked{label: :name, token: "vt_name"},
                 :reveal_name,
                 __MODULE__,
                 repo: nil
               )
    end

    test "the fleet-admin actor is refused by Reveal.reveal/5, structurally" do
      assert {:error, :fleet_actor_denied} =
               Samen.Reveal.reveal(
                 AdminActor.new("op-1"),
                 %Samen.Masked{label: :name, token: "vt_name"},
                 :reveal_name,
                 __MODULE__,
                 repo: nil
               )
    end
  end
end
