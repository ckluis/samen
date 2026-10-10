defmodule Driftwood.ReplayDevDemoTest do
  @moduledoc """
  ADR-052 §2.4 — session replay is demoable in Driftwood DEV, and only there:

    * `config/dev.exs` turns the capture plane on (`replay:` with the flag loader scoped to
      replay); `config/test.exs` and `config/prod.exs` never do (the runtime child list carries
      no `Samen.Replay.Supervisor` without it);
    * `Driftwood.Seeds.seed_replay_flag/1` (run by `mix driftwood.seed`) opts exactly the given
      org in: with the dev loader the flag is ON for it and OFF for any other org (positive
      control + red path), and a second run changes nothing;
    * the flag is the OPERATOR's (ADR-052 §2.4.1 item 7): the seeded row lives in the operator
      org, the dev loader reads only that org's rows, and a tenant admin's own `samen.replay`
      row — created through the kernel's admin-gated action — turns capture neither ON for
      itself or another org nor OFF for the opted-in org.
  """
  use Driftwood.DataCase, async: false

  require Ash.Query

  alias Samen.FeatureFlags.Cache

  @config Path.expand("../config/config.exs", __DIR__)

  setup do
    Cache.invalidate_all()
    on_exit(fn -> Cache.invalidate_all() end)
    :ok
  end

  defp replay_opt(env) do
    @config
    |> Config.Reader.read!(env: env, target: :host)
    |> get_in([:driftwood, Samen.Observability, :replay])
  end

  test "capture is configured ON in dev only" do
    assert [flag_opts: [flag_module: Driftwood.Primitives.FeatureFlag, owner_org_id: owner]] =
             replay_opt(:dev)

    assert owner == Application.fetch_env!(:driftwood, :operator_org_id)
    assert owner == Driftwood.OperatorSeeds.operator_org_id()
    assert replay_opt(:test) in [nil, false]
    assert replay_opt(:prod) in [nil, false]

    # Dev's option list builds ONE capture supervisor; test's child list has none.
    refute Enum.any?(
             Samen.Observability.child_specs(:driftwood),
             &match?({Samen.Replay.Supervisor, _}, &1)
           )

    assert Enum.any?(
             Samen.Observability.child_specs(:driftwood, replay: replay_opt(:dev)),
             &match?({Samen.Replay.Supervisor, _}, &1)
           )
  end

  test "the dev seed opts exactly its org in (the dev loader reads the seeded flag row)" do
    org = Driftwood.Seeds.blue_ridge_org_id()
    other = Ash.UUID.generate()
    cfg = Samen.Replay.config!(replay_opt(:dev))

    # Before the seed: the flag is unknown, so OFF for every org (fail-safe).
    refute Samen.Replay.flag_on?(org, cfg)

    :ok = Driftwood.Seeds.seed_replay_flag(org)
    :ok = Driftwood.Seeds.seed_replay_flag(org)

    assert Samen.Replay.flag_on?(org, cfg)
    refute Samen.Replay.flag_on?(other, cfg)

    %{rows: [[1]]} =
      Repo.query!("SELECT count(*) FROM fff_feature_flag WHERE fff_name = $1", [
        Samen.Replay.flag_name()
      ])
  end

  test "CROSS-TENANT: a tenant admin's own samen.replay row cannot change any org's capture" do
    blue_ridge = Driftwood.Seeds.blue_ridge_org_id()
    tenant_b = Ash.UUID.generate()
    tenant_c = Ash.UUID.generate()
    cfg = Samen.Replay.config!(replay_opt(:dev))
    name = Samen.Replay.flag_name()
    admin = fn org -> %{org_id: org, role: :admin, plane: :tenant, kind: :tenant} end

    # Tenant rows land BEFORE the operator's: the old loader read the first row of any org.
    # B rolls capture out to everyone; Blue Ridge's own admin writes a killed row. Both go
    # through the kernel's admin-gated create, as a tenant admin can.
    tenant_row = fn org, attrs ->
      Driftwood.Primitives.FeatureFlag
      |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, name: name}, attrs),
        actor: admin.(org)
      )
      |> Ash.create!()
    end

    tenant_row.(tenant_b, %{enabled: true, rollout_pct: 100})
    tenant_row.(blue_ridge, %{enabled: false})

    :ok = Driftwood.Seeds.seed_replay_flag(blue_ridge)

    # Positive control: the operator's row opts Blue Ridge in, the tenant kill notwithstanding.
    assert Samen.Replay.flag_on?(blue_ridge, cfg)
    refute Samen.Replay.flag_on?(tenant_b, cfg)
    refute Samen.Replay.flag_on?(tenant_c, cfg)

    # The opt-in itself is out of the tenant's reach: it lives in the operator org.
    operator = Driftwood.OperatorSeeds.operator_org_id()

    [seeded] =
      Driftwood.Primitives.FeatureFlag
      |> Ash.Query.filter(name == ^name and org_id == ^operator)
      |> Ash.read!(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             seeded
             |> Ash.Changeset.for_update(:update, %{rollout_pct: 100}, actor: admin.(blue_ridge))
             |> Ash.update()
  end
end
