defmodule Samen.Web.ApiKeysHygieneTest do
  @moduledoc """
  WS-E E5.2 — API-KEY CREDENTIAL HYGIENE + AUTHORITY CEILING (ADR-029; AC-G18-3/4;
  RP-ST-2 / RP-ST-3). The API-key settings surface mints show-once, digest-only keys
  whose authority can never out-reach the minting membership's role.

    * **RP-ST-2 (show-once, digest-only)** — `mint/3` returns the raw key ONCE; the row
      stores ONLY `token_digest` (SHA-256); the raw is nowhere in the DB and never
      re-displayed by `list/2`. The committed `12-e5-apikey-store-raw` patch stores the
      RAW key in `token_digest` (the classic leak), which FLIPS the hygiene tests.
    * **RP-ST-3 (minter ceiling)** — `effective_scopes/2` intersects requested scopes
      with the minter role's ceiling BEFORE the row is written (`write` needs `>= member`,
      `read` needs `>= viewer`). The committed `13-e5-apikey-ceiling-bypass` patch returns
      the requested scopes verbatim (escalation), which FLIPS the ceiling test.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.ApiKeys

  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.User

  defp mount, do: Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Plane.tenant())

  defp admin_scope(user_id, org_id, role \\ :admin) do
    %Samen.Scope{actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant}}
  end

  defp seed_membership!(org_id, role \\ :admin) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "admin"})
      |> Ash.create!(authorize?: false)

    membership =
      Membership
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
      |> Ash.create!(authorize?: false)

    {user, membership}
  end

  defp digest_ref(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  # ==========================================================================
  # RP-ST-2 — show-once, digest-only (AC-G18-3)
  # ==========================================================================

  describe "API-key mint is show-once and digest-only (RP-ST-2 · AC-G18-3)" do
    test "mint returns the raw key ONCE; the row stores only its SHA-256 digest, never the key" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed_membership!(org_id)

      assert {:ok, raw, row} =
               ApiKeys.mint(mount(), admin_scope(user.id, org_id),
                 membership_id: membership.id,
                 minter_role: :admin,
                 scopes: %{all: [:read]}
               )

      # The raw is high-entropy material; the stored digest is its SHA-256 — NOT the raw.
      assert String.starts_with?(raw, "sk_")
      assert row.token_digest == digest_ref(raw)
      refute row.token_digest == raw
    end

    test "the raw key is NOWHERE in the persisted row (the DB cannot leak what it never stored)" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed_membership!(org_id)

      {:ok, raw, row} =
        ApiKeys.mint(mount(), admin_scope(user.id, org_id),
          membership_id: membership.id,
          minter_role: :admin,
          scopes: %{all: [:read, :write]}
        )

      %{rows: [[digest]]} =
        Samen.WebTest.Repo.query!(
          "SELECT wok_token_digest FROM wok_api_key WHERE wok_id = $1",
          [Ecto.UUID.dump!(row.id)]
        )

      assert digest == digest_ref(raw)
      refute digest == raw
      refute digest =~ raw
    end

    test "list/2 never re-displays the raw key — only a digest prefix + bounded metadata" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed_membership!(org_id)

      {:ok, raw, _row} =
        ApiKeys.mint(mount(), admin_scope(user.id, org_id),
          membership_id: membership.id,
          minter_role: :admin,
          scopes: %{all: [:read]}
        )

      [view | _] = ApiKeys.list(mount(), admin_scope(user.id, org_id))

      refute Map.has_key?(view, :raw)
      refute Map.has_key?(view, :token)
      refute view.digest_prefix == raw
      assert view.digest_prefix == String.slice(digest_ref(raw), 0, 12)
      assert view.plane == :tenant
    end
  end

  # ==========================================================================
  # RP-ST-3 — the minter authority ceiling (AC-G18-4)
  # ==========================================================================

  describe "minted-key authority never exceeds the minter role ceiling (RP-ST-3 · AC-G18-4)" do
    test "a viewer minter cannot grant write — effective_scopes strips it (the ceiling)" do
      # SABOTAGE (13-e5): returning the requested scopes verbatim keeps :write here,
      # which FLIPS this assertion.
      assert ApiKeys.effective_scopes(%{all: [:read, :write]}, :viewer) == %{all: [:read]}
    end

    test "a member minter keeps read+write; an owner keeps them too (the ceiling admits)" do
      assert ApiKeys.effective_scopes(%{all: [:read, :write]}, :member) == %{all: [:read, :write]}
      assert ApiKeys.effective_scopes(%{billing: [:read, :write]}, :owner) == %{billing: [:read, :write]}
    end

    test "an empty requested set (or an unknown action) grants nothing — deny-by-default" do
      assert ApiKeys.effective_scopes(%{}, :owner) == %{}
      assert ApiKeys.effective_scopes(%{all: [:delete]}, :owner) == %{}
    end

    test "the STORED row carries only the ceiling-bounded scopes (a viewer key is read-only at rest)" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed_membership!(org_id)

      # Even asking for write, a viewer-ceilinged key stores read-only — the row cannot
      # carry escalated authority.
      {:ok, _raw, row} =
        ApiKeys.mint(mount(), admin_scope(user.id, org_id),
          membership_id: membership.id,
          minter_role: :viewer,
          scopes: %{all: [:read, :write]}
        )

      assert row.scopes == %{"all" => ["read"]} or row.scopes == %{all: [:read]}
    end
  end

  # ==========================================================================
  # Revoke
  # ==========================================================================

  describe "revoke sets revoked_at (the list marks it revoked)" do
    test "a revoked key is marked revoked and stops being active" do
      org_id = Ash.UUID.generate()
      {user, membership} = seed_membership!(org_id)
      scope = admin_scope(user.id, org_id)

      {:ok, _raw, row} =
        ApiKeys.mint(mount(), scope, membership_id: membership.id, minter_role: :admin, scopes: %{all: [:read]})

      assert {:ok, view} = ApiKeys.revoke(mount(), scope, row.id)
      assert view.revoked?
      assert [listed | _] = ApiKeys.list(mount(), scope)
      assert listed.revoked?
    end
  end
end
