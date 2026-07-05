defmodule Samen.Reveal.GrantSeamTest do
  @moduledoc """
  T1.6: wire T1.5's `:reveal` seam (`Samen.Reveal`) to consult the grant model
  (`Samen.Reveal.Grants`) for operator-class actors.

  With `config :samen_core, :reveal_grant, Samen.Reveal.Grants`, a `:reveal`
  action:
    * DENIES when there is no active grant for the (actor, subject) — fail closed;
    * SUCCEEDS (reaches the vault) only with an active, unexpired, distinct-party
      grant;
    * DENIES again once the grant expires (deny-on-read).
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias Samen.Reveal
  alias Samen.Reveal.Grants
  alias SamenCore.Support.RevealDomain.RevealPerson

  @repo SamenCore.TestRepo
  @resource RevealPerson

  # A vault stub so the seam integration test doesn't require a stored vault row —
  # the grant gate is what we're proving here, not the vault decrypt.
  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "plaintext@revealed.test"}
  end

  defmodule ExplodingVault do
    def reveal(_masked, _repo, _opts \\ []),
      do: raise("vault reached on a denied reveal — grant gate failed to fail closed")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  test "operator with NO grant is DENIED and never reaches the vault" do
    masked = Masked.new("vt_seam_token", :emails)

    assert {:error, :denied} =
             Reveal.reveal(actor(), masked, :reveal_email, @resource,
               repo: @repo,
               subject_id: subj(),
               grant: Grants,
               vault: ExplodingVault
             )
  end

  test "operator WITH an active distinct-party grant reveals via the vault" do
    s = subj()
    requestor = actor()
    approver = actor()
    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
    {:ok, _grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})

    masked = Masked.new("vt_seam_token", :emails)

    # The reveal capability binds to the REQUESTOR (P1 authz fix), authorized by
    # the DISTINCT approver. The requestor reveals; the approver does not.
    assert {:ok, "plaintext@revealed.test"} =
             Reveal.reveal(requestor, masked, :reveal_email, @resource,
               repo: @repo,
               subject_id: s,
               grant: Grants,
               vault: OkVault
             )
  end

  test "RED PATH: once the grant is revoked, the seam denies again (re-access needs a fresh grant)" do
    s = subj()
    requestor = actor()
    approver = actor()
    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
    {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 60})

    masked = Masked.new("vt_seam_token", :emails)

    assert {:ok, _} =
             Reveal.reveal(requestor, masked, :reveal_email, @resource,
               repo: @repo,
               subject_id: s,
               grant: Grants,
               vault: OkVault
             )

    {:ok, _} = Grants.revoke(grant.id)

    assert {:error, :denied} =
             Reveal.reveal(requestor, masked, :reveal_email, @resource,
               repo: @repo,
               subject_id: s,
               grant: Grants,
               vault: ExplodingVault
             )
  end
end
