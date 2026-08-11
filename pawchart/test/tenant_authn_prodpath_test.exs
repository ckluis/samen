defmodule PawChart.TenantAuthnProdPathTest do
  @moduledoc """
  PP-1 / PP-2 (Batch 5a PAWCHART-SPINE) — pawchart is now a properly-authenticated tenant host.
  Its PII-bearing tenant mounts carry the `:authn` seam (over `@current_org_labels`), so on an
  ARMED host `Samen.Web.CurrentOrg.resolve/3` runs the fail-closed authorized path — an
  authenticated clinic member resolves its OWN org, and the W4 cross-tenant `?org=` attack is
  denied. This is the pawchart analog of `Driftwood.AuthProdPathTest` + the framework
  `Samen.Web.TenantAuthnCoverageTest`, exercised against pawchart's REAL compiled router.

  The mounts are extracted off `PawChartWeb.Router` (not hand-built), so a router that DROPS the
  `:authn` seam (the Batch-5a sabotage) flips these assertions — pawchart passes because it is
  WIRED, never by exclusion.

  Paired red/control (anti-tautology, `Samen.RedPath` spirit):
    * GREEN — armed host, an AUTHENTICATED member (real `PawChart.Operator` Membership) resolves
      its OWN org (via the authorized path, NOT a trusted `?org=`).
    * RED — armed host, an UNAUTHENTICATED `?org=<other-org>` resolves NO org (the W4 leak closed),
      for EVERY PII-bearing tenant mount.
    * REFUTABILITY — DISARMED (dev/test), the SAME mounts still trust the `?org=` convenience: the
      GREEN denial is produced by the armed fail-closed branch, not vacuously.
  """
  use PawChart.DataCase, async: false

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  # A guessable-format clinic org UUID an attacker supplies — the SHAPE the pawchart landing page
  # printed in the W4 live repro. It is NOT the caller's own org (there is no caller).
  @attacker_org "c1112d00-0000-4000-8000-0000000000ff"
  @session_user_key "samen_current_user"

  # The PII-bearing tenant-MODULE scope kinds pawchart mounts (the ones Batch-1's coverage guard
  # enumerates). `:settings`/`:auth` identity mounts are the self-serve/pre-actor plane and are
  # handled by the spine tests, not this business-domain enumeration.
  @tenant_kinds ~w(crm billing support work marketing notifications files csv ics search)a

  setup do
    prev = Application.get_env(:pawchart, :auth_required?)
    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:pawchart, :auth_required?)
        v -> Application.put_env(:pawchart, :auth_required?, v)
      end
    end)

    :ok
  end

  defp arm!, do: Application.put_env(:pawchart, :auth_required?, true)
  defp disarm!, do: Application.put_env(:pawchart, :auth_required?, false)

  # Seed a real clinic member (User + Membership under the PawChart.Operator identity spine) so
  # the `:authorized_orgs` seam (`PawChart.Auth.authorized_org_ids/1`) resolves a REAL org set.
  defp seed_member!(org_id, role) do
    user =
      PawChart.Operator.User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "clinic-#{role}-#{System.unique_integer([:positive])}"})
      |> Ash.create!(authorize?: false)

    PawChart.Operator.Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  # ==========================================================================
  # POSITIVE CONTROL — an authenticated clinic member resolves its OWN org.
  # ==========================================================================

  describe "GREEN: armed pawchart, an authenticated member resolves its own org (the authorized path)" do
    test "an authenticated member with a real Membership resolves its OWN org (no ?org= needed)" do
      org_id = Ecto.UUID.generate()
      user = seed_member!(org_id, :admin)
      arm!()

      crm_mount = tenant_mount!(:crm)
      session = %{@session_user_key => user.id}

      # No ?org= at all → the member's own authorized org.
      assert CurrentOrg.resolve(crm_mount, %{}, session) == org_id
      # A ?org= INSIDE the authorized set is honored (a legit deep link to its own org).
      assert CurrentOrg.resolve(crm_mount, %{"org" => org_id}, session) == org_id
    end

    test "a ?org= OUTSIDE the authorized set never resolves the target — lands on the member's own org" do
      org_id = Ecto.UUID.generate()
      user = seed_member!(org_id, :member)
      arm!()

      crm_mount = tenant_mount!(:crm)
      session = %{@session_user_key => user.id}

      # The attacker org is NOT in the member's authorized set → lands on its own org, never target.
      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, session) == org_id
    end

    test "an authenticated principal with NO provisioned membership derives no actor (fail closed)" do
      arm!()
      crm_mount = tenant_mount!(:crm)
      session = %{@session_user_key => Ecto.UUID.generate()}

      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, session) == nil
    end
  end

  # ==========================================================================
  # RED — reproduce W4's cross-tenant attack against pawchart's REAL mounts.
  # ==========================================================================

  describe "RED: armed pawchart denies an unauthenticated ?org= on EVERY PII-bearing tenant mount" do
    test "the exact W4 vector — cookieless ?org=<other-org> to /crm → NO org (no PII)" do
      arm!()
      crm_mount = tenant_mount!(:crm)

      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, %{}) == nil
      assert CurrentOrg.resolve(crm_mount, %{}, %{"samen_current_org" => @attacker_org}) == nil
      assert CurrentOrg.resolve(crm_mount, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil
    end

    test "EVERY enumerated PII-bearing tenant mount denies an unauthenticated ?org= on the armed host" do
      arm!()
      mounts = tenant_mounts()

      assert length(mounts) >= 6,
             "tenant-mount enumeration looks broken (too few PII-bearing tenant live routes found)"

      for {path, mount} <- mounts do
        assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil,
               "ARMED pawchart tenant mount #{path} resolved an org from an UNAUTHENTICATED ?org= — " <>
                 "the PP-1 cross-tenant leak is open on this mount"
      end
    end
  end

  # ==========================================================================
  # REFUTABILITY — disarmed dev posture still trusts ?org= (non-vacuous).
  # ==========================================================================

  test "REFUTABILITY: DISARMED, the pawchart tenant mounts still resolve the dev ?org= convenience" do
    disarm!()

    for {path, mount} <- tenant_mounts() do
      assert CurrentOrg.resolve(mount, %{"org" => @attacker_org}, %{}) == @attacker_org,
             "DISARMED pawchart tenant mount #{path} did NOT keep the dev ?org= convenience — the " <>
               "refutability control is broken (the armed denial would be vacuous)"
    end
  end

  test "every enumerated tenant mount carries the :authn seam (the guard reflects the wiring)" do
    for {path, mount} <- tenant_mounts() do
      assert Mount.label(mount, :authn, nil) == {:app_env, :pawchart, :auth_required?},
             "pawchart tenant mount #{path} is missing the :authn seam"
    end
  end

  # ==========================================================================
  # Residual B (Batch 7) — /clinic is INDIVIDUALLY pinned (per-mount, not per-scope-kind).
  # ==========================================================================

  describe "Residual B: the /clinic tenant mount is individually enumerated + authn-gated" do
    test "/clinic is present in the enumeration (not folded into the /crm module mount)" do
      clinic = Enum.find(tenant_mounts(), fn {path, _m} -> path == "/clinic" end)

      assert clinic,
             "/clinic must be INDIVIDUALLY enumerated (per-live-session dedup), not deduped away " <>
               "by the /crm module mount that shares its :crm scope_kind — else a /clinic-only " <>
               "mount divergence slips past the coverage guard"

      {_path, mount} = clinic
      assert mount.scope_kind == :crm

      assert Mount.label(mount, :authn, nil) == {:app_env, :pawchart, :auth_required?},
             "/clinic's tenant mount must carry the :authn seam (its own divergence must be caught)"
    end

    test "armed pawchart denies an unauthenticated ?org= on the /clinic mount specifically" do
      arm!()
      {_path, clinic} = Enum.find(tenant_mounts(), fn {path, _m} -> path == "/clinic" end)

      assert CurrentOrg.resolve(clinic, %{"org" => @attacker_org}, %{}) == nil
      assert CurrentOrg.resolve(clinic, %{}, %{"samen_current_org" => @attacker_org}) == nil
      assert CurrentOrg.resolve(clinic, %{"org" => @attacker_org}, %{"samen_current_org" => @attacker_org}) == nil
    end
  end

  # -- helpers -------------------------------------------------------------------

  defp tenant_mount!(kind) do
    {_path, mount} =
      tenant_mounts()
      |> Enum.find(fn {_path, m} -> m.scope_kind == kind end)

    mount
  end

  # Enumerate the PII-bearing tenant LiveView routes off the compiled pawchart router and rebuild
  # the serialized `Samen.Web.Mount` each `live_session` threads through its session.
  #
  # Residual B (Batch 7) — dedup PER LIVE_SESSION (per distinct tenant MOUNT adoption point), NOT
  # per `scope_kind`. `/clinic` is its OWN `:pawchart_clinic` live_session but shares the `:crm`
  # scope_kind with the `/crm/*` module mount (defined earlier), so the old `uniq_by(scope_kind)`
  # dropped `/clinic` as a non-representative — a `/clinic`-only mount divergence (e.g. a dropped
  # `:authn` seam) could slip past the enumeration entirely. Keying on the live_session name pins
  # EVERY distinct PII-bearing tenant mount individually, `/clinic` included, so a per-mount
  # divergence flips this guard.
  defp tenant_mounts do
    PawChartWeb.Router.__routes__()
    |> Enum.filter(&Map.has_key?(&1.metadata, :phoenix_live_view))
    |> Enum.map(fn route -> {route.path, live_session_name(route), mount_of(route)} end)
    |> Enum.reject(fn {_path, _ls, mount} -> is_nil(mount) end)
    |> Enum.filter(fn {_path, _ls, mount} -> mount.scope_kind in @tenant_kinds end)
    |> Enum.uniq_by(fn {_path, ls, _mount} -> ls end)
    |> Enum.map(fn {path, _ls, mount} -> {path, mount} end)
  end

  defp live_session_name(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}),
    do: live_session[:name]

  defp live_session_name(_), do: nil

  defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    case get_in(live_session, [:extra, :session]) do
      %{"samen_mount" => raw} -> Mount.from_session(raw)
      _ -> nil
    end
  end

  defp mount_of(_), do: nil
end
