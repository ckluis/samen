defmodule Samen.Web.TenantAuthnCoverageTest do
  @moduledoc """
  PP-1 / PP-3 (Batch 1, ADR-031) — the framework tenant-plane auth gate now FAILS CLOSED, and
  the class is closed by an ENUMERATING guard rather than a per-vertical patch.

  Live-reproduced defect (dogfood W4): pawchart's tenant plane served UNMASKED cross-tenant PII
  to a cookieless `curl` carrying `?org=<uuid>`, because `Samen.Web.CurrentOrg.resolve/3` fell
  OPEN — a tenant mount without an `:authn` label dropped to the dev path that trusts the
  caller-supplied `?org=` in EVERY environment, and NO verifier caught the divergence between
  driftwood (adopted the seam) and pawchart (never did).

  This is the analog of `Samen.Web.FleetCockpitAuthzTest` (RP-J-12): where that test enumerates
  every operator route and asserts each carries the `:require_operator` on_mount, THIS test
  enumerates every PII-bearing TENANT mount (off a REAL compiled router, `Samen.WebTest.TenantAuthn`)
  and asserts the SECURITY PROPERTY — an unauthenticated `?org=` request resolves NO org (denied) —
  for EVERY one. Approach (a) from the batch brief: we assert the fail-closed BEHAVIOR (pawchart's
  unlabeled mounts are safe-because-DENIED), never an allow-list that excuses them.

  Paired red/control per `Samen.RedPath` (anti-tautology):
    * RED (attack) — armed host, an unauthenticated `?org=<other-org>` to an UNLABELED
      (pawchart-shaped) tenant mount resolves `nil` (the leak is closed).
    * REFUTABILITY — the SAME unlabeled mount, DISARMED, still resolves the `?org=` param: proves
      the RED assertion is closed by the fail-closed branch, not vacuously true.
    * CONTROL — driftwood's correctly `:authn`-labelled mount still WORKS: an authenticated member
      in its authorized orgs resolves its own org; an unauthenticated caller still denies.
  """
  use ExUnit.Case, async: false

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.WebTest.TenantAuthn
  alias Samen.WebTest.TenantAuthn.{LabeledTenantRouter, UnlabeledTenantRouter}

  @otp_app TenantAuthn.otp_app()

  # A guessable-format tenant org UUID an attacker supplies — the SHAPE the pawchart landing
  # page printed in the W4 live repro. It is NOT the caller's own org (there is no caller).
  @attacker_org "c1112d00-0000-4000-8000-000000000001"

  # An authenticated member of the positive-control host, authorized for exactly one org.
  @member_user "user-authenticated-9"
  @member_org "d2223e00-0000-4000-8000-000000000002"
  @session_user_key "samen_current_user"

  setup do
    prev = Application.get_env(@otp_app, :auth_required?)
    prev_authorized = Application.get_env(:samen_web, :tenant_authn_authorized_orgs)

    on_exit(fn ->
      restore(@otp_app, :auth_required?, prev)
      restore(:samen_web, :tenant_authn_authorized_orgs, prev_authorized)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  defp arm!, do: Application.put_env(@otp_app, :auth_required?, true)
  defp disarm!, do: Application.put_env(@otp_app, :auth_required?, false)

  # ==========================================================================
  # The ENUMERATING guard (PP-3) — the class-closer, mirroring RP-J-12.
  # ==========================================================================

  describe "PP-3 — every PII-bearing tenant mount (enumerated) denies an unauthenticated ?org= on an armed host" do
    test "GREEN: on an ARMED host, EVERY tenant live mount — labeled or NOT — resolves NO org for an unauthenticated ?org=" do
      arm!()

      mounts = tenant_mounts(UnlabeledTenantRouter) ++ tenant_mounts(LabeledTenantRouter)

      assert length(mounts) >= 6,
             "tenant-mount enumeration looks broken (too few PII-bearing tenant live routes found)"

      for {path, mount} <- mounts do
        # Unauthenticated: a raw `?org=` + a sticky session org, NO authenticated principal.
        assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil,
               "ARMED tenant mount #{path} resolved an org from an UNAUTHENTICATED ?org= — the PP-1 " <>
                 "cross-tenant leak is open on this mount"
      end
    end

    test "REFUTABILITY: the enumeration is not vacuous — DISARMED, the unlabeled mounts DO resolve the ?org= param" do
      # Anti-tautology twin of the GREEN test: prove the denial above is produced by the armed
      # fail-closed branch, not by `resolve/3` always returning nil. In the sanctioned disarmed
      # dev posture, the unlabeled mounts STILL trust the dev convenience (local ergonomics kept).
      disarm!()

      for {path, mount} <- tenant_mounts(UnlabeledTenantRouter) do
        assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{}) == @attacker_org,
               "DISARMED tenant mount #{path} did NOT keep the dev ?org= convenience — the " <>
                 "refutability control is broken (the GREEN denial would be vacuous)"
      end
    end
  end

  # ==========================================================================
  # Reproduce-the-attack (PP-1) — the exact W4 vector, closed.
  # ==========================================================================

  describe "PP-1 — reproduce W4's cross-tenant attack against a pawchart-shaped unlabeled mount" do
    test "RED: armed host, cookieless ?org=<other-org> to the unlabeled CRM contacts mount → NO org (no PII)" do
      arm!()

      {_path, crm_mount} = crm_mount(UnlabeledTenantRouter)

      # The W4 repro: `curl ".../crm/contacts?org=<clinic-org>"` with zero cookies. Fail closed.
      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, %{}) == nil
      # And with a sticky session org (an operator "Open account →" write) — still denied.
      assert CurrentOrg.resolve(crm_mount, %{}, %{"samen_current_org" => @attacker_org}) == nil
      # No default/directory label rescues it either: the unlabeled mount yields no actor.
      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil
    end
  end

  # ==========================================================================
  # POSITIVE CONTROL (driftwood) — the correctly-labelled mount still works.
  # ==========================================================================

  describe "positive control — driftwood's :authn-labelled tenant mount resolves the authenticated tenant's own org" do
    test "CONTROL: armed host, an AUTHENTICATED member in its authorized orgs resolves its OWN org" do
      arm!()
      Application.put_env(:samen_web, :tenant_authn_authorized_orgs, %{@member_user => [@member_org]})

      {_path, labeled_crm} = crm_mount(LabeledTenantRouter)
      session = %{@session_user_key => @member_user}

      # A real authenticated principal, no ?org= at all → its own authorized org.
      assert CurrentOrg.resolve(labeled_crm, %{}, session) == @member_org
      # A ?org= INSIDE the authorized set is honored (a legit deep link to its own org).
      assert CurrentOrg.resolve(labeled_crm, %{"org" => @member_org}, session) == @member_org
    end

    test "CONTROL: a ?org= OUTSIDE the authorized set never resolves the target — lands on the member's own org" do
      arm!()
      Application.put_env(:samen_web, :tenant_authn_authorized_orgs, %{@member_user => [@member_org]})

      {_path, labeled_crm} = crm_mount(LabeledTenantRouter)
      session = %{@session_user_key => @member_user}

      # The attacker org is NOT in the member's authorized set → the member lands on its own org,
      # never the target (the authorized path constrains, it does not trust the param).
      assert CurrentOrg.resolve(labeled_crm, %{"org" => @attacker_org}, session) == @member_org
    end

    test "CONTROL: the labelled mount ALSO denies an unauthenticated ?org= (no principal → nil)" do
      arm!()

      {_path, labeled_crm} = crm_mount(LabeledTenantRouter)

      assert CurrentOrg.resolve(labeled_crm, %{"org" => @attacker_org}, %{}) == nil
    end
  end

  # ==========================================================================
  # Refutability control for the enumeration helper itself (anti-tautology).
  # ==========================================================================

  test "REFUTABILITY CONTROL: mount extraction reads real serialized mounts (not vacuously empty)" do
    mounts = tenant_mounts(UnlabeledTenantRouter)
    assert length(mounts) >= 6
    assert Enum.all?(mounts, fn {_path, m} -> match?(%Mount{}, m) end)
    # Every extracted mount is the pawchart-shaped UNLABELED shape (no :authn seam).
    assert Enum.all?(mounts, fn {_path, m} -> Mount.label(m, :authn, nil) == nil end)
  end

  # -- helpers -------------------------------------------------------------------

  # Enumerate the PII-bearing tenant LiveView routes off a compiled router and rebuild the
  # serialized `Samen.Web.Mount` each `live_session` threads through its session (the exact
  # mount the LiveView's `mount/3` deserializes and hands to `CurrentOrg.resolve/3`).
  defp tenant_mounts(router) do
    router.__routes__()
    |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
    |> Enum.map(fn route -> {route.path, mount_of(route)} end)
    |> Enum.reject(fn {_path, mount} -> is_nil(mount) end)
    |> Enum.uniq_by(fn {_path, mount} -> mount end)
  end

  defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    case get_in(live_session, [:extra, :session]) do
      %{"samen_mount" => raw} -> Mount.from_session(raw)
      _ -> nil
    end
  end

  defp mount_of(_), do: nil

  # The first CRM tenant mount off a router (the `/crm/contacts`-class surface the W4 repro hit).
  defp crm_mount(router) do
    tenant_mounts(router)
    |> Enum.find(fn {path, _mount} -> String.starts_with?(path, "/crm") end)
  end
end
