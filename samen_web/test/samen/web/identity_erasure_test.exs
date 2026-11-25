defmodule Samen.Web.IdentityErasureTest do
  @moduledoc """
  Blind-index erasure wiring (authorization and erasure round 4, C). Erasing the principal account
  through the real entry point (`Samen.Erasure.shred/2`) must clear every keyed hash of the erased
  person's email on the identity resources, with NO host configuration: the identity mount's
  blind-index columns are derived from the live schema at shred time.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query
  import Ecto.Query, only: [from: 2]

  alias Samen.Auth.BlindIndex
  alias Samen.Identity.Register
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.LoginFailure
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    prev_specs = Application.get_env(:samen_core, :blind_index_erasure_specs)
    Application.put_env(:samen_core, :delivery_env, :test)
    # The state of a host that never called Samen.Erasure.install_default_specs/1.
    Application.delete_env(:samen_core, :blind_index_erasure_specs)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)

      if prev_specs,
        do: Application.put_env(:samen_core, :blind_index_erasure_specs, prev_specs),
        else: Application.delete_env(:samen_core, :blind_index_erasure_specs)
    end)

    :ok
  end

  defp register! do
    email = "erase-#{System.unique_integer([:positive])}@example.test"

    {:ok, result} =
      Register.register(
        %{org_name: "Erase Co #{System.unique_integer([:positive])}", first_name: "Eve", last_name: "Erased", email: email, password: "correct horse battery staple"},
        %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}
      )

    {result, email}
  end

  defp stored(mod, id, field) do
    mod |> Ash.Query.filter(id == ^id) |> Ash.Query.select([:id, field]) |> Ash.read_one!(authorize?: false) |> Map.fetch!(field)
  end

  test "RED: erasing the principal account clears the credential's email_bidx without any host config" do
    {result, email} = register!()
    {:ok, bidx} = BlindIndex.compute(email)
    cid = result.credential.id

    # positive control: the equality oracle exists before the erasure
    assert stored(Credential, cid, :email_bidx) == bidx

    assert {:ok, %{report: report}} = Samen.Erasure.shred(cid, repo: Repo)

    refute stored(Credential, cid, :email_bidx) == bidx
    assert Enum.any?(report.tiers["blind_index"], &(&1["resource"] =~ "Credential" and &1["rows_tombstoned"] == 1))
  end

  test "RED: the login-failure counters keyed on the erased email's bidx and on the credential are deleted" do
    {result, email} = register!()
    {:ok, bidx} = BlindIndex.compute(email)
    cid = result.credential.id

    Samen.Identity.LoginFailure.bump!(LoginFailure, :email_bidx, bidx, 900)
    Samen.Identity.LoginFailure.bump!(LoginFailure, :credential, cid, 900)

    {:ok, other_bidx} = BlindIndex.compute("someone-else-#{System.unique_integer([:positive])}@example.test")
    Samen.Identity.LoginFailure.bump!(LoginFailure, :email_bidx, other_bidx, 900)

    assert {:ok, _} = Samen.Erasure.shred(cid, repo: Repo)

    keys = LoginFailure |> Ash.read!(authorize?: false) |> Enum.map(&{&1.key_kind, &1.key_value})
    refute {:email_bidx, bidx} in keys
    refute {:credential, cid} in keys
    # CONTROL: another person's counter is untouched
    assert {:email_bidx, other_bidx} in keys
  end

  test "a per-tenant data-subject shred (the User) leaves the credential's email_bidx and the cross-org login alone" do
    {result, email} = register!()
    {:ok, bidx} = BlindIndex.compute(email)

    assert {:ok, _} = Samen.Erasure.shred(result.user.id, repo: Repo)
    assert stored(Credential, result.credential.id, :email_bidx) == bidx
  end

  describe "an invitation is the inviting org's own record (ADR-046 4.1, 1b)" do
    defp invite_mods,
      do: %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Repo}

    test "account erasure leaves the invitation alone; erasing the invitation itself clears it" do
      {person, email} = register!()
      {inviter, _} = register!()
      {:ok, bidx} = BlindIndex.compute(email)

      scope = %Samen.Scope{
        actor: %{id: inviter.user.id, org_id: inviter.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
      }

      {:ok, invitation, _raw} = Samen.Identity.Invite.create(invite_mods(), scope, %{email: email, role: :member})
      assert stored(Invitation, invitation.id, :email_bidx) == bidx

      assert {:ok, _} = Samen.Erasure.shred(person.credential.id, repo: Repo)

      # The ADR gives an Invitation its OWN subject (its id) and keeps it in the inviting org's data: the person's
      # account erasure does not reach it. (CHANGELOG states exactly this.)
      refute stored(Credential, person.credential.id, :email_bidx) == bidx
      assert stored(Invitation, invitation.id, :email_bidx) == bidx

      # CONTROL: erasing the invitation as its own subject does tombstone its index
      assert {:ok, %{report: report}} = Samen.Erasure.shred(invitation.id, repo: Repo)
      refute stored(Invitation, invitation.id, :email_bidx) == bidx
      assert Enum.any?(report.tiers["blind_index"], &(&1["resource"] =~ "Invitation" and &1["rows_tombstoned"] == 1))
    end
  end

  test "fail-honest: a blind-index column erasure cannot cover fails the erasure instead of reporting success" do
    defmodule Uncovered do
      use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

      attributes do
        uuid_primary_key(:id)
        attribute(:phone_bidx, :string)
      end
    end

    assert [{Uncovered, :phone_bidx}] = Samen.Auth.BlindIndexErasure.uncovered([Uncovered])

    assert_raise ArgumentError, ~r/phone_bidx/, fn ->
      Samen.Auth.BlindIndexErasure.erase_subject(Ash.UUID.generate(), Repo, resources: [Uncovered])
    end
  end

  defmodule UncoveredPhone do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:phone_bidx, :string)
    end
  end

  describe "Samen.Erasure.shred/2 refuses BEFORE destroying anything when a blind index cannot be cleared" do
    test "RED: an uncovered _bidx column refuses the shred; the key survives and no report is written" do
      {result, _email} = register!()
      cid = result.credential.id
      {:ok, _} = Samen.Vault.store_field(cid, :pii_email, :emails, "key-maker@example.test", Repo)

      # positive control: the subject has a live key before the call
      assert Samen.Kms.adapter().key_material_present?(cid)

      assert {:error, {:blind_index_uncovered, [{UncoveredPhone, :phone_bidx}]}} =
               Samen.Erasure.shred(cid, repo: Repo, resources: [UncoveredPhone])

      assert Samen.Kms.adapter().key_material_present?(cid), "the refusal must come BEFORE the key is destroyed"
      refute Samen.Erasure.erased?(cid, repo: Repo)
      assert Repo.aggregate(from(r in Samen.Erasure.Report, where: r.subject_id == ^cid), :count) == 0

      # CONTROL: with the schema this host really has, the very same call erases
      assert {:ok, _} = Samen.Erasure.shred(cid, repo: Repo)
      refute Samen.Kms.adapter().key_material_present?(cid)
    end

    test "RED: a derivation that finds no resources is refused, never reported as 'nothing to clear'" do
      {result, email} = register!()
      {:ok, bidx} = BlindIndex.compute(email)
      cid = result.credential.id
      {:ok, _} = Samen.Vault.store_field(cid, :pii_email, :emails, "key-maker@example.test", Repo)

      assert {:error, {:blind_index_no_resources, _lookup}} = Samen.Erasure.shred(cid, repo: Repo, resources: [])

      assert Samen.Kms.adapter().key_material_present?(cid)
      assert stored(Credential, cid, :email_bidx) == bidx
    end

    test "an explicit :bidx_specs list is the caller's own scope: not derived, not coverage-checked" do
      {result, _email} = register!()

      assert {:ok, %{report: report}} = Samen.Erasure.shred(result.credential.id, repo: Repo, bidx_specs: [], resources: [UncoveredPhone])
      assert report.tiers["blind_index"] == []
    end
  end

  test "guard: every blind-index column of the identity mount is covered by a derived spec; LoginFailure is purged" do
    resources = Samen.Erasure.Completeness.resources(domains: [Samen.WebTest.Operator])

    assert Samen.Auth.BlindIndexErasure.uncovered(resources) == []

    covered = for s <- Samen.Auth.BlindIndexErasure.derived_specs(resources), do: {s.table_name, s.bidx_column}
    assert length(covered) >= 3, "the identity mount must derive Credential.email_bidx, Invitation.email_bidx and AuthToken.sent_to_bidx"
    assert [%{table_name: _}] = Samen.Auth.BlindIndexErasure.login_failure_tables(resources)
  end
end
