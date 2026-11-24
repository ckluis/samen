defmodule Samen.Web.IdentityErasureTest do
  @moduledoc """
  Blind-index erasure wiring (authorization and erasure round 4, C). Erasing the principal account
  through the real entry point (`Samen.Erasure.shred/2`) must clear every keyed hash of the erased
  person's email on the identity resources, with NO host configuration: the identity mount's
  blind-index columns are derived from the live schema at shred time.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Auth.BlindIndex
  alias Samen.Identity.Register
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
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

  test "guard: every blind-index column of the identity mount is covered by a derived spec; LoginFailure is purged" do
    resources = Samen.Erasure.Completeness.resources(domains: [Samen.WebTest.Operator])

    assert Samen.Auth.BlindIndexErasure.uncovered(resources) == []

    covered = for s <- Samen.Auth.BlindIndexErasure.derived_specs(resources), do: {s.table_name, s.bidx_column}
    assert length(covered) >= 3, "the identity mount must derive Credential.email_bidx, Invitation.email_bidx and AuthToken.sent_to_bidx"
    assert [%{table_name: _}] = Samen.Auth.BlindIndexErasure.login_failure_tables(resources)
  end
end
