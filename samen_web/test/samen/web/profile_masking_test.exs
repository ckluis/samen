defmodule Samen.Web.ProfileMaskingTest do
  @moduledoc """
  WS-E E5.1 — THE PROFILE SELF-EDIT MASKING RED-PATH (ADR-029; AC-G18-2; RP-ST-1).
  Profile self-edit of own vaulted PII is the fourth new masking-watch-list surface
  WS-E closes: a user edits their OWN `full_name`/`emails`, and the write MUST route
  through the SAME `WriteGuard` + `Vault.Change` chokepoint the CRUD forms + CSV import
  prove — a self-edit is not a plaintext-write bypass, and an operator impersonating the
  user cannot silently write plaintext into the masked field.

  Consumer of `Samen.MaskingCase` (E2i.1) — the green/red/sabotage discipline shared with
  the file-preview, notifications, CSV-export, and search-projection masking tests.

    * **GREEN (read)** — the user's own tenant plane resolves the vaulted `full_name`
      CLEAR; a tenant-plane self-edit writes `vt_*` at rest (plaintext nowhere).
    * **RED (write)** — an operator impersonating the user is REFUSED a plaintext PII
      write by `Samen.Web.Settings.Profile.update/4` (WriteGuard) — the DB is unchanged.
    * **SABOTAGE twin** — the committed `11-e5-profile-plaintext-write` patch drops the
      governed scope from `Profile.update` (an operator write then succeeds), which FLIPS
      the RED test; and the read leak-scan is refutable (a tenant-plane read of the SAME
      row DOES carry the plaintext the operator read masks).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Masked
  alias Samen.Type.FullName
  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Settings.Profile
  alias Samen.Web.Settings.Reads

  alias Samen.WebTest.Operator.User

  @secret_first "VaultedProfileFirst"
  @secret_last "Profile-Self-Edit-Secret"
  @op_first "OperatorAuthored"
  @op_last "PlaintextInjection"

  defmodule DenyAllGrant do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  defmodule AllowAllGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defp settings_mount(plane_opts \\ []) do
    build_mount(:settings, plane_opts)
  end

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "profile-mask-session"), org_id)

  defp seed_user!(org_id, first \\ @secret_first, last \\ @secret_last) do
    User
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      handle: "me",
      full_name: %FullName{first: first, last: last},
      emails: [%{address: "secret.person@example.test"}]
    })
    |> Ash.create!(authorize?: false)
  end

  # Re-read with the vault-routed fields SELECTED (at-rest %Masked{}); the resolver
  # decides clear-vs-•••• per plane — the same posture Reads.get_user runs.
  defp reload_user!(id) do
    require Ash.Query

    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:full_name, :emails, :handle, :org_id])
    |> Ash.read_one!(authorize?: false)
  end

  defp raw_full_name(id) do
    %{rows: [[raw]]} =
      Samen.WebTest.Repo.query!(
        "SELECT wou_full_name FROM wou_user WHERE wou_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    raw
  end

  # ==========================================================================
  # 1. Read seam — the profile full_name resolves per plane (AC-G18-2 read half)
  # ==========================================================================

  describe "profile PII resolution per plane (AC-G18-2 · RP-ST-1 read half)" do
    test "TENANT plane resolves the vaulted full_name CLEAR (green)" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id) |> Map.get(:id) |> reload_user!()

      resolved = resolve_on_plane(user, User, :tenant, repo: Samen.WebTest.Repo)

      refute match?(%Masked{}, resolved.full_name)
      full = inspect(resolved.full_name)
      assert full =~ @secret_first
      assert full =~ @secret_last
      refute full =~ "vt_"
    end

    test "OPERATOR-WITHOUT-GRANT resolves full_name to %Masked{} — ••••, never plaintext (RP-ST-1)" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id) |> Map.get(:id) |> reload_user!()

      resolved = resolve_on_plane(user, User, :operator, repo: Samen.WebTest.Repo, grant: DenyAllGrant)

      assert_plane_masked!(resolved.full_name)
      masked = to_string(resolved.full_name)
      assert masked == mask()
      refute masked =~ @secret_first
      refute masked =~ "vt_"
    end

    test "OPERATOR-WITH-GRANT resolves CLEAR — the two-plane reveal rule (green)" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id) |> Map.get(:id) |> reload_user!()

      resolved = resolve_on_plane(user, User, :operator, repo: Samen.WebTest.Repo, grant: AllowAllGrant)

      refute match?(%Masked{}, resolved.full_name)
      assert inspect(resolved.full_name) =~ @secret_first
    end

    test "the plane is the gate — same record tenant clear ∧ operator masked (anti-tautology)" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id) |> Map.get(:id) |> reload_user!()

      tenant = resolve_on_plane(user, User, :tenant, repo: Samen.WebTest.Repo)
      operator = resolve_on_plane(user, User, :operator, repo: Samen.WebTest.Repo, grant: DenyAllGrant)

      refute match?(%Masked{}, tenant.full_name)
      assert match?(%Masked{}, operator.full_name)
      assert inspect(tenant.full_name) =~ @secret_first
      assert to_string(operator.full_name) == mask()
    end
  end

  # ==========================================================================
  # 2. Write chokepoint — the governed self-edit, per plane (AC-G18-2 write half)
  # ==========================================================================

  describe "profile self-edit routes through the vault write chokepoint (RP-ST-1 write half)" do
    test "GREEN: a tenant self-edit writes full_name as vt_* — plaintext nowhere at rest" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id, "Old", "Name")
      mount = settings_mount()

      assert {:ok, _} =
               Profile.update(mount, tenant_scope(org_id), user.id, %{
                 full_name: %{first: @secret_first, last: @secret_last}
               })

      raw = raw_full_name(user.id)
      assert is_binary(raw)
      assert String.starts_with?(raw, "vt_")
      refute raw =~ @secret_first
      refute raw =~ @secret_last
    end

    test "RED: an operator-impersonation plaintext PII write is REFUSED — DB unchanged (RP-ST-1)" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id)
      mount = settings_mount(plane: :operator, target_org_id: org_id)

      before = raw_full_name(user.id)

      # SABOTAGE (11-e5): dropping the governed scope from Profile.update lets this
      # operator plaintext write succeed — which FLIPS this assertion.
      assert {:error, _} =
               Profile.update(mount, operator_scope(org_id), user.id, %{
                 full_name: %{first: @op_first, last: @op_last}
               })

      after_write = raw_full_name(user.id)
      assert before == after_write
      refute after_write =~ @op_first
      refute after_write =~ @op_last
    end

    test "ANTI-TAUTOLOGY: the SAME edit on the tenant plane SUCCEEDS — the plane is the gate" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id)
      mount = settings_mount()

      # The operator-refused edit lands cleanly on the tenant plane (the resolver/guard's
      # only difference is the actor's :plane) — proving the refusal is plane-specific.
      assert {:ok, _} =
               Profile.update(mount, tenant_scope(org_id), user.id, %{
                 full_name: %{first: @op_first, last: @op_last}
               })

      raw = raw_full_name(user.id)
      assert String.starts_with?(raw, "vt_")
      refute raw =~ @op_first
    end

    test "SABOTAGE refutability: a tenant-plane READ of the row DOES carry the plaintext" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id) |> Map.get(:id) |> reload_user!()

      # Model the leak the mask prevents: the SAME row read clear on the tenant plane
      # carries the plaintext the operator read masks — the refute is non-vacuous.
      leaked = resolve_on_plane(user, User, :tenant, repo: Samen.WebTest.Repo)
      assert inspect(leaked.full_name) =~ @secret_first
    end
  end

  # ==========================================================================
  # 3. The Reads seam end-to-end (get_user resolves per plane)
  # ==========================================================================

  describe "Settings.Reads.get_user resolves per plane" do
    test "tenant get_user is clear; operator get_user masks full_name" do
      org_id = Ash.UUID.generate()
      user = seed_user!(org_id)

      {:ok, tenant_user} =
        Reads.get_user(settings_mount(), tenant_scope(org_id), user.id)

      refute match?(%Masked{}, tenant_user.full_name)
      assert inspect(tenant_user.full_name) =~ @secret_first

      {:ok, op_user} =
        Reads.get_user(
          Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo,
            plane: Plane.operator("op-1", org_id, "s")
          ),
          operator_scope(org_id),
          user.id
        )

      assert match?(%Masked{}, op_user.full_name)
      refute to_string(op_user.full_name) =~ @secret_first
    end
  end
end
