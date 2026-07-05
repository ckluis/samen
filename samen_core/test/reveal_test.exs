defmodule Samen.RevealTest do
  @moduledoc """
  T1.5 clause (c): the `:reveal` action as a FIRST-CLASS introspectable marker,
  and the `Samen.Reveal` grant seam (default deny).

  Red path: an ungranted `:reveal` DENIES (never returns plaintext, never touches
  the vault decrypt path). Introspection is declaration-driven, NOT name-matched
  (Gate-0 fix task #6) — a `:read_email_looks_like_reveal` action is NOT a reveal
  action.
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias Samen.Pii.Info
  alias Samen.Reveal
  alias SamenCore.Support.RevealDomain.RevealPerson

  @resource RevealPerson
  @masked Masked.new("vt_reveal_test_token", :emails)

  # A grant checker that approves everything — the T1.6 seam, stubbed to APPROVE.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  # A grant checker that records the context it was asked about (proves the seam
  # is actually consulted, and that the marker gate runs BEFORE it).
  defmodule Recorder do
    @behaviour Samen.Reveal.Grant
    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def contexts, do: Agent.get(__MODULE__, & &1)
    @impl true
    def granted?(ctx) do
      Agent.update(__MODULE__, &[ctx | &1])
      false
    end
  end

  # A stub vault to prove that on deny, the vault is NEVER called.
  defmodule ExplodingVault do
    def reveal(_masked, _repo, _opts \\ []) do
      raise "vault reached on a denied reveal — the grant gate failed to fail closed"
    end
  end

  # A stub vault that returns a sentinel plaintext when reached (granted path).
  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "plaintext@revealed.test"}
  end

  # ===================================================================
  # First-class introspection (declaration-driven, not name-matched)
  # ===================================================================

  describe "reveal marker introspection (real, declaration-driven)" do
    test "reveal_actions/1 returns the DECLARED reveal action" do
      assert Info.reveal_actions(@resource) == MapSet.new([:reveal_email])
    end

    test "reveal_action?/2 is true for the declared action" do
      assert Info.reveal_action?(@resource, :reveal_email)
    end

    test "reveal_action?/2 is FALSE for a non-declared action whose NAME contains 'reveal'" do
      # Gate-0 fix #6: the marker keys on the DECLARATION, not the action name.
      # :read_email_looks_like_reveal is a real action but was NOT declared reveal.
      refute Info.reveal_action?(@resource, :read_email_looks_like_reveal)
    end

    test "reveal_action?/2 is false for an ordinary action (:read)" do
      refute Info.reveal_action?(@resource, :read)
    end

    test "a resource with no reveal markers has an empty reveal set (default deny)" do
      assert Info.reveal_actions(SamenCore.Support.Crm.Contact) == MapSet.new([])
      refute Info.reveal_action?(SamenCore.Support.Crm.Contact, :read)
    end
  end

  # ===================================================================
  # RED PATH: ungranted :reveal denies (default DenyAll)
  # ===================================================================

  describe "RED PATH — ungranted :reveal denies" do
    test "default grant checker is DenyAll (fail closed)" do
      # No :reveal_grant configured → DenyAll.
      Application.delete_env(:samen_core, :reveal_grant)
      assert Reveal.grant_checker() == Samen.Reveal.DenyAll
    end

    test "reveal on a declared action with NO grant returns {:error, :denied}, never plaintext" do
      result =
        Reveal.reveal(:some_actor, @masked, :reveal_email, @resource,
          repo: SamenCore.TestRepo,
          grant: Samen.Reveal.DenyAll,
          vault: ExplodingVault
        )

      assert result == {:error, :denied}
    end

    test "on deny, the vault decrypt path is NEVER reached (ExplodingVault stays silent)" do
      # If the grant gate leaked, ExplodingVault.reveal/3 would raise. It must not.
      assert {:error, :denied} =
               Reveal.reveal(:actor, @masked, :reveal_email, @resource,
                 repo: SamenCore.TestRepo,
                 grant: Samen.Reveal.DenyAll,
                 vault: ExplodingVault
               )
    end

    test "reveal on a NON-reveal action denies with :not_reveal_action (marker gate)" do
      # Even with an APPROVING grant, a non-declared action cannot produce plaintext.
      assert {:error, :not_reveal_action} =
               Reveal.reveal(:actor, @masked, :read_email_looks_like_reveal, @resource,
                 repo: SamenCore.TestRepo,
                 grant: ApproveAll,
                 vault: OkVault
               )
    end

    test "the marker gate runs BEFORE the grant gate (grant not even consulted)" do
      {:ok, _} = Recorder.start()

      assert {:error, :not_reveal_action} =
               Reveal.reveal(:actor, @masked, :read_email_looks_like_reveal, @resource,
                 repo: SamenCore.TestRepo,
                 grant: Recorder,
                 vault: OkVault
               )

      # A non-reveal action short-circuits before the grant checker is asked.
      assert Recorder.contexts() == []
    end
  end

  # ===================================================================
  # GRANTED path: a reveal action + approving grant → plaintext (once)
  # ===================================================================

  describe "granted :reveal returns plaintext through the single chokepoint" do
    test "declared action + approving grant → {:ok, plaintext} via the vault" do
      assert {:ok, "plaintext@revealed.test"} =
               Reveal.reveal(:actor, @masked, :reveal_email, @resource,
                 repo: SamenCore.TestRepo,
                 grant: ApproveAll,
                 vault: OkVault
               )
    end

    test "the grant checker IS consulted with the right context on the granted path" do
      {:ok, _} = Recorder.start()

      # Recorder denies but records — proving the context carries the action,
      # resource, actor, and label the T1.6 grant model keys on.
      assert {:error, :denied} =
               Reveal.reveal(:actor42, @masked, :reveal_email, @resource,
                 subject_id: "subj-xyz",
                 repo: SamenCore.TestRepo,
                 grant: Recorder,
                 vault: OkVault
               )

      [ctx] = Recorder.contexts()
      assert ctx.actor == :actor42
      assert ctx.action == :reveal_email
      assert ctx.resource == @resource
      assert ctx.subject_id == "subj-xyz"
      assert ctx.label == :emails
    end
  end
end
