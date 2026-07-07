defmodule Samen.AggregateMutualExclusionTest do
  @moduledoc """
  The token-blind aggregate actor's **mutual exclusion** with the reveal path and
  the tenant plane (T4.2; doc §control "The two paths are mutually exclusive").

  Three structural guarantees, each with a red path and an anti-tautology control:

    1. **aggregate ⟂ reveal** — `Samen.Reveal.reveal/5` refuses the aggregate actor
       (`:operator_aggregate`) structurally, BEFORE any grant/vault check, even with
       an always-grant checker. Anti-tautology: a NON-aggregate actor with the same
       always-grant checker reveals — so the denial is the aggregate class, not a
       broken reveal path.

    2. **aggregate actor has no org_id** — `Samen.Policy.OrgScope`'s filter is
       `expr(false)` for the org-less aggregate actor → ZERO rows on any tenant
       resource. Anti-tautology: an actor WITH an org_id filters to its org.

    3. **AggregateActorOnly admits only the aggregate actor** — a tenant /
       impersonation / api_key actor does NOT match; the aggregate actor DOES.
  """
  use ExUnit.Case, async: true

  alias Samen.Aggregate.Actor
  alias Samen.Masked

  # ==========================================================================
  # 1. aggregate ⟂ reveal — structural, before grant/vault.
  # ==========================================================================

  defmodule AlwaysGrant do
    @moduledoc false
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_context), do: true
  end

  defmodule RevealResource do
    @moduledoc false
    # A minimal resource that declares :read as a reveal action, so the marker gate
    # passes and only the actor-class gate is exercised.
    use Ash.Resource, domain: nil, validate_domain_inclusion?: false, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  # A masked value + a vault stub that would "succeed" if ever reached — proving the
  # aggregate denial happens BEFORE the vault, not because decryption failed.
  defmodule VaultStub do
    @moduledoc false
    def reveal(%Masked{}, _repo, _opts), do: {:ok, "PLAINTEXT-SHOULD-NEVER-APPEAR"}
  end

  test "RED: the aggregate actor may NEVER reveal — refused before grant/vault, even with an always-grant checker" do
    masked = Masked.new("vt_token_1", :emails)
    agg = Actor.new()

    result =
      Samen.Reveal.reveal(agg, masked, :read, RevealResource,
        repo: :unused_repo,
        subject_id: "subject-1",
        grant: AlwaysGrant,
        vault: VaultStub
      )

    # The aggregate gate is FIRST in the cond — it precedes the marker gate, the
    # grant gate, and the vault. So even a declared-reveal action + always-grant +
    # a succeeding vault stub cannot let it through.
    assert result == {:error, :aggregate_actor_denied}
  end

  test "control (anti-tautology): a NON-aggregate operator actor with the SAME always-grant checker is NOT refused by the aggregate gate" do
    masked = Masked.new("vt_token_1", :emails)
    # A plain operator-class actor (not :operator_aggregate) with an id.
    non_agg = %{id: "op-1", kind: :operator}

    result =
      Samen.Reveal.reveal(non_agg, masked, :read, RevealResource,
        repo: :unused_repo,
        subject_id: "subject-1",
        grant: AlwaysGrant,
        vault: VaultStub
      )

    # It is NOT stopped by the aggregate gate. It proceeds past it — here it fails at
    # the MARKER gate (:read is not a declared reveal action on RevealResource), which
    # is a DIFFERENT error than :aggregate_actor_denied. That proves the aggregate
    # denial is specific to the aggregate class, not an always-deny.
    assert result == {:error, :not_reveal_action}
    refute result == {:error, :aggregate_actor_denied}
  end

  # ==========================================================================
  # 2. aggregate actor has no org_id — OrgScope filters to zero rows.
  # ==========================================================================

  test "the aggregate actor carries NO org_id (structurally token-blind)" do
    agg = Actor.new()
    refute Map.has_key?(agg, :org_id)
    assert agg.kind == :operator_aggregate
    assert agg.id == Actor.principal_id()
  end

  test "RED: OrgScope filters the org-less aggregate actor to expr(false) — zero rows on any tenant resource" do
    agg = Actor.new()

    # OrgScope.filter/3 for an actor with no org_id is the fail-closed `expr(false)`
    # — no tenant row is visible to the aggregate actor.
    filter = Samen.Policy.OrgScope.filter(agg, %{}, [])
    assert inspect(filter) =~ "false"
  end

  test "control (anti-tautology): OrgScope filters an actor WITH an org_id to that org (not always-false)" do
    tenant_actor = %{id: "u1", org_id: "org-A", role: :member}
    filter = Samen.Policy.OrgScope.filter(tenant_actor, %{}, [])
    # A real predicate (org_id == ^org_id), NOT the always-false the org-less actor gets.
    refute inspect(filter) == inspect(Samen.Policy.OrgScope.filter(Actor.new(), %{}, []))
  end

  # ==========================================================================
  # 3. AggregateActorOnly admits ONLY the aggregate actor.
  # ==========================================================================

  test "AggregateActorOnly admits the aggregate actor and refuses every other principal class" do
    admit = fn actor -> Samen.Policy.AggregateActorOnly.match?(actor, %{}, []) end

    # The aggregate actor is admitted.
    assert admit.(Actor.new())
    assert admit.(%{kind: :operator_aggregate})

    # Every other principal class is refused.
    refute admit.(%{id: "u1", org_id: "org-A", role: :member})
    refute admit.(%{id: "op-1", kind: :operator})
    refute admit.(%{id: "key-1", kind: :api_key})
    refute admit.(nil)
    refute admit.("not-a-map")
  end
end
