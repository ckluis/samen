defmodule Driftwood.ReplayDevDemoTest do
  @moduledoc """
  ADR-052 §2.4 — session replay is demoable in Driftwood DEV, and only there:

    * `config/dev.exs` turns the capture plane on (`replay:` with the flag loader scoped to
      replay); `config/test.exs` and `config/prod.exs` never do (the runtime child list carries
      no `Samen.Replay.Supervisor` without it);
    * `Driftwood.Seeds.seed_replay_flag/1` (run by `mix driftwood.seed`) opts exactly the given
      org in: with the dev loader the flag is ON for it and OFF for any other org (positive
      control + red path), and a second run changes nothing.
  """
  use Driftwood.DataCase, async: false

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
    assert [flag_opts: [flag_module: Driftwood.Primitives.FeatureFlag]] = replay_opt(:dev)
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
end
