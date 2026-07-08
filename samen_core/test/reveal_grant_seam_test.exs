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

  # A grant checker that approves everything — used to isolate the DOWNSTREAM
  # vault subject-bind (F4.1): even with the grant satisfied for subject X, the
  # real vault must deny when the masked token is really subject Y's.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
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

  # F4.1 routine-path bind: a grant for subject X (approved) with a masked token
  # that is REALLY subject Y's must deny at the vault chokepoint, never returning
  # Y's plaintext under X's grant/audit. Uses the REAL Samen.Vault so the bind
  # actually fires against a stored row.
  test "RED PATH: grant for subject X but a masked token for subject Y DENIES :subject_mismatch" do
    prior_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    # Restore to a REAL adapter, never nil: if this test runs before any adapter is
    # explicitly set, `prior_kms` is nil, and writing nil back overrides the
    # `Kms.adapter/0` default (FileBacked), leaking `nil` into the global env and
    # crashing a later test with `nil.attest/1`. Guard with `|| FileBacked` — the
    # same pattern break_glass_test/wide_event_pseudonym_test already use.
    on_exit(fn ->
      Application.put_env(:samen_core, :kms_adapter, prior_kms || Samen.Kms.FileBacked)
    end)

    subject_x = subj()
    subject_y = subj()

    # Y's REAL vaulted secret + token.
    {:ok, token_y} =
      Samen.Vault.store_field(subject_y, :pii_email, :emails, "yankee-SECRET@y.test", @repo)

    masked_y = Masked.new(token_y, :emails)

    # The grant gate approves for subject X; the vault must still deny because the
    # token is Y's. No plaintext for Y crosses the seam under X's grant.
    assert {:error, :subject_mismatch} =
             Reveal.reveal(actor(), masked_y, :reveal_email, @resource,
               repo: @repo,
               subject_id: subject_x,
               grant: ApproveAll,
               vault: Samen.Vault
             )

    # Positive control: with the token's REAL subject, the same real-vault reveal
    # succeeds (the bind is not always-deny).
    assert {:ok, "yankee-SECRET@y.test"} =
             Reveal.reveal(actor(), masked_y, :reveal_email, @resource,
               repo: @repo,
               subject_id: subject_y,
               grant: ApproveAll,
               vault: Samen.Vault
             )
  end
end
