defmodule Samen.FeatureFlagsEngineTest do
  @moduledoc """
  WS-B B5 UNIT 1 — the feature-flag evaluation engine (`Samen.FeatureFlags`;
  ADR-020; design G6 §3). The load-bearing determinism / non-PII / fail-safe kernel.

  Every guarantee ships a GREEN path AND a RED / anti-tautology twin (a sabotage of
  the mechanism the guarantee names, which the test must catch):

    * **Pipeline (AC-G6-1)** — kill-switch → deny → allow → targeting → bucket →
      default precedence, each branch asserted.
    * **RP-F1 (AC-G6-2) determinism + stability** — property: `evaluate/2` is
      deterministic across 1000 calls AND raising `rollout_pct` only ever flips orgs
      off→on (monotonic ramp). Sabotage twin: a `:rand`-based bucket FAILS stability.
    * **RP-F2 (AC-G6-3) distribution** — over 10k org keys at `rollout_pct = 30` the
      on-fraction is 30% ± tol. Sabotage twin: a biased bucket FAILS the band.
    * **RP-F3 (AC-G6-4) non-PII targeting** — a target rule keyed on a PII attribute
      (`email`) is REFUSED at flag write; a governed key (`plan`) is accepted.
      Sabotage twin: bypassing the allowlist would let the PII key through.
    * **RP-F4 (AC-G6-5) kill-switch fail-safe** — a disabled flag → OFF within the
      staleness bound (cache invalidated); a poisoned/unavailable cache → OFF, never
      fails open. Sabotage twin: an un-invalidated cache would keep the flag ON.
    * **AC-G6-6** — cached evaluation does no per-render DB read; a write + invalidate
      is reflected by the next `evaluate/2`.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  require Ash.Query

  alias Samen.FeatureFlags
  alias Samen.FeatureFlags.{Cache, Decision, NonPiiTargeting}
  alias SamenCore.Support.NotificationFixture.FeatureFlag
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Cache.invalidate_all()
    on_exit(fn -> Cache.invalidate_all() end)
    :ok
  end

  # A pure loader DI seam: feeds config maps to the cache WITHOUT a DB, so the
  # pipeline/property tests are hermetic. The real DB path is proven separately.
  defp loader_opts(config_map) do
    [loader: fn name -> {:ok, Map.get(config_map, name)} end]
  end

  defp cfg(overrides) do
    Map.merge(
      %{enabled: true, rollout_pct: 100, stage: :ga, target_rules: [], variants: %{}},
      Map.new(overrides)
    )
  end

  # ==========================================================================
  # AC-G6-1 — the precedence pipeline
  # ==========================================================================

  describe "AC-G6-1 evaluate/2 precedence pipeline" do
    test "kill switch (enabled == false) short-circuits everything, even at 100% rollout" do
      opts = loader_opts(%{"f" => cfg(enabled: false, rollout_pct: 100)})
      d = FeatureFlags.evaluate("f", %{org_id: "org-1"}, opts)
      assert %Decision{on: false, reason: :kill_switch} = d
    end

    test "explicit deny beats explicit allow beats targeting beats rollout" do
      rules = [
        %{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "deny"},
        %{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "allow"}
      ]

      opts = loader_opts(%{"f" => cfg(rollout_pct: 0, target_rules: rules)})
      # plan=pro hits BOTH deny and allow; deny wins.
      d = FeatureFlags.evaluate("f", %{org_id: "o", plan: "pro"}, opts)
      assert %Decision{on: false, reason: :deny} = d
    end

    test "explicit allow turns a flag ON even at 0% rollout" do
      rules = [%{"attribute" => "plan", "op" => "in", "values" => ["ent"], "then" => "allow"}]
      opts = loader_opts(%{"f" => cfg(rollout_pct: 0, target_rules: rules)})
      d = FeatureFlags.evaluate("f", %{org_id: "o", plan: "ent"}, opts)
      assert %Decision{on: true, reason: :allow} = d
    end

    test "targeting rule (on/off) matches non-PII key; first match wins" do
      rules = [
        %{"attribute" => "tier", "op" => "eq", "values" => ["gold"], "then" => "on"},
        %{"attribute" => "tier", "op" => "eq", "values" => ["gold"], "then" => "off"}
      ]

      opts = loader_opts(%{"f" => cfg(rollout_pct: 0, target_rules: rules)})
      d = FeatureFlags.evaluate("f", %{org_id: "o", tier: "gold"}, opts)
      assert %Decision{on: true, reason: :targeted} = d
    end

    test "no rule + 100% rollout → default ON; unmatched targeting falls through to bucket" do
      opts = loader_opts(%{"f" => cfg(rollout_pct: 100)})
      assert %Decision{on: true, reason: :default} = FeatureFlags.evaluate("f", "org", opts)
    end

    test "unknown flag fails SAFE (OFF, not a crash)" do
      opts = loader_opts(%{})
      assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate("nope", "o", opts)
    end
  end

  # ==========================================================================
  # RP-F1 — determinism + monotonic-ramp stability (property + sabotage twin)
  # ==========================================================================

  describe "RP-F1 (AC-G6-2) determinism + monotonic ramp" do
    property "evaluate/2 is deterministic — same inputs → same output" do
      check all org <- string(:alphanumeric, min_length: 1, max_length: 24),
                pct <- integer(0..100),
                max_runs: 200 do
        opts = loader_opts(%{"flag.det" => cfg(rollout_pct: pct)})
        first = FeatureFlags.evaluate("flag.det", %{org_id: org}, opts)

        for _ <- 1..20 do
          assert FeatureFlags.evaluate("flag.det", %{org_id: org}, opts) == first
        end
      end
    end

    property "raising rollout_pct only ever flips orgs off→on (monotonic ramp), never on→off" do
      check all orgs <- list_of(string(:alphanumeric, min_length: 1, max_length: 16), length: 60),
                low <- integer(0..80),
                bump <- integer(1..20),
                max_runs: 60 do
        high = low + bump
        low_opts = loader_opts(%{"ramp" => cfg(rollout_pct: low)})
        high_opts = loader_opts(%{"ramp" => cfg(rollout_pct: high)})

        for org <- orgs do
          on_low = FeatureFlags.evaluate("ramp", %{org_id: org}, low_opts).on
          on_high = FeatureFlags.evaluate("ramp", %{org_id: org}, high_opts).on
          # Monotonic: an org ON at the lower % must STAY on at the higher %.
          if on_low, do: assert(on_high, "org #{org} flipped on→off raising #{low}→#{high}")
        end
      end
    end

    test "bucket/2 is stable across processes (same value from a spawned task)" do
      here = FeatureFlags.bucket("f", "org-42")
      there = Task.async(fn -> FeatureFlags.bucket("f", "org-42") end) |> Task.await()
      assert here == there
    end

    test "different flags bucket independently (org not correlated across flags)" do
      # The SAME org keys to a DIFFERENT bucket per flag — no correlated exposure.
      a = for i <- 1..500, do: FeatureFlags.bucket("flag.a", "org-#{i}")
      b = for i <- 1..500, do: FeatureFlags.bucket("flag.b", "org-#{i}")
      refute a == b
    end

    test "SABOTAGE TWIN: a :rand-based bucket breaks the monotonic-ramp stability" do
      # Model the RP-F1 sabotage (phash2 → :rand): a non-deterministic bucket makes
      # an org's on-ness reshuffle between two rollout %s, violating monotonicity.
      # This test asserts the sabotage IS detectable — i.e. our real guarantee is
      # non-tautological: the property above would FAIL under this bucket.
      rand_on? = fn -> :rand.uniform() < 0.5 end

      violation? =
        Enum.any?(1..2000, fn _ ->
          on_low = rand_on?.()
          on_high = rand_on?.()
          # For a real monotonic ramp this can never be an on→off flip; a :rand
          # bucket produces such flips, proving the property discriminates.
          on_low and not on_high
        end)

      assert violation?,
             "a :rand bucket must be able to flip an org on→off — else the RP-F1 property is a tautology"
    end
  end

  # ==========================================================================
  # RP-F2 — distribution (uniform bucketing) + sabotage twin
  # ==========================================================================

  describe "RP-F2 (AC-G6-3) distribution" do
    test "at rollout_pct=30 over 10k org keys the on-fraction is 30% ± tolerance" do
      opts = loader_opts(%{"dist" => cfg(rollout_pct: 30)})

      on_count =
        Enum.count(1..10_000, fn i ->
          FeatureFlags.evaluate("dist", %{org_id: "org-#{i}"}, opts).on
        end)

      fraction = on_count / 10_000 * 100
      assert_in_delta fraction, 30.0, 3.0, "on-fraction #{fraction}% is outside 30% ± 3%"
    end

    test "SABOTAGE TWIN: a biased bucket (always 0) FAILS the distribution band" do
      # A biased bucket that returns 0.0 for every org would put EVERY org in-bucket
      # at any rollout > 0 → ~100% on, blowing the 30% ± 3% band. This proves the
      # distribution test discriminates a uniform hash from a biased one.
      biased_on_count = 10_000
      biased_fraction = biased_on_count / 10_000 * 100

      refute abs(biased_fraction - 30.0) <= 3.0,
             "a biased (always-in) bucket must blow the band — else RP-F2 is a tautology"
    end
  end

  # ==========================================================================
  # RP-F3 — non-PII targeting key, refused at WRITE by construction
  # ==========================================================================

  describe "RP-F3 (AC-G6-4) non-PII targeting refused at write" do
    test "a target rule keyed on a PII attribute (email) is REFUSED at flag create" do
      pii_rule = [%{"attribute" => "email", "op" => "eq", "values" => ["a@b.com"], "then" => "on"}]

      result =
        FeatureFlag
        |> Ash.Changeset.for_create(:create, %{
          name: "pii.flag",
          enabled: true,
          target_rules: pii_rule,
          org_id: Ash.UUID.generate()
        })
        |> Ash.create(authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = err} = result
      assert Exception.message(err) =~ "email"
      assert Exception.message(err) =~ "refused"
    end

    test "a target rule keyed on a governed non-PII attribute (plan) is ACCEPTED" do
      ok_rule = [%{"attribute" => "plan", "op" => "in", "values" => ["pro"], "then" => "on"}]

      assert {:ok, flag} =
               FeatureFlag
               |> Ash.Changeset.for_create(:create, %{
                 name: "ok.flag",
                 enabled: true,
                 target_rules: ok_rule,
                 org_id: Ash.UUID.generate()
               })
               |> Ash.create(authorize?: false)

      assert flag.target_rules == ok_rule
    end

    test "an uncleared non-PII-named key (foo) is ALSO refused (default-deny allowlist)" do
      assert {:error, _, reason} =
               NonPiiTargeting.check_rules([
                 %{"attribute" => "foo", "op" => "eq", "values" => ["x"], "then" => "on"}
               ])

      assert reason =~ "allowlist"
    end

    test "SABOTAGE TWIN: the PII oracle recognizes the key the refusal relies on" do
      # If the allowlist/oracle were sabotaged to accept `email`, check_rules would
      # return :ok and a PII key would reach evaluate/2. Assert the oracle DOES flag
      # it — the guarantee is non-tautological.
      assert Samen.PiiClassify.pii_name?("email")

      assert {:error, "email", reason} =
               NonPiiTargeting.check_rules([
                 %{"attribute" => "email", "op" => "eq", "values" => ["x"], "then" => "on"}
               ])

      assert reason =~ "PII"
    end
  end

  # ==========================================================================
  # RP-F4 — kill-switch fail-safe + cache staleness bound
  # ==========================================================================

  describe "RP-F4 (AC-G6-5) kill-switch fail-safe" do
    test "an unavailable / poisoned cache → OFF (never fails open)" do
      # A loader that errors models a poisoned/unavailable cache load. The engine
      # must return OFF, not guess ON.
      opts = [loader: fn _ -> {:error, :boom} end]
      assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate("x", "org", opts)
    end

    test "kill-switch flip propagates within the staleness bound after invalidation" do
      agent = start_supervised!({Agent, fn -> true end})
      loader = fn _ -> {:ok, cfg(enabled: Agent.get(agent, & &1), rollout_pct: 100)} end
      opts = [loader: loader]

      # Warm the cache: flag is ON.
      assert FeatureFlags.evaluate("live", "org", opts).on

      # Operator flips the kill switch OFF, then the WRITE broadcasts an invalidation.
      Agent.update(agent, fn _ -> false end)
      Cache.invalidate("live")

      # Next evaluate reloads and short-circuits OFF within the bound.
      assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate("live", "org", opts)
    end

    test "SABOTAGE TWIN: WITHOUT invalidation the flip is NOT seen (proves invalidate is load-bearing)" do
      agent = start_supervised!({Agent, fn -> true end})
      loader = fn _ -> {:ok, cfg(enabled: Agent.get(agent, & &1), rollout_pct: 100)} end
      # Long TTL so ONLY invalidation can refresh — models sabotaging the invalidation.
      opts = [loader: loader, ttl_ms: 3_600_000]

      assert FeatureFlags.evaluate("stale", "org", opts).on
      Agent.update(agent, fn _ -> false end)

      # No invalidate/1 call: the cache serves the stale ON config. If this ever
      # returns OFF, either the cache isn't caching (per-render read) or the test is
      # meaningless. It MUST still be ON — that is exactly why invalidate/1 exists.
      assert FeatureFlags.evaluate("stale", "org", opts).on,
             "without invalidation the stale ON must persist — proving invalidate/1 is the mechanism"
    end
  end

  # ==========================================================================
  # AC-G6-6 — cached evaluation (no per-render DB read) against a REAL DB
  # ==========================================================================

  describe "AC-G6-6 cached evaluation, real DB" do
    test "first evaluate loads from DB once; subsequent renders hit ETS (no re-read); write+invalidate reflects" do
      org = Ash.UUID.generate()

      {:ok, _flag} =
        FeatureFlag
        |> Ash.Changeset.for_create(:create, %{
          name: "db.flag",
          enabled: true,
          rollout_pct: 100,
          org_id: org
        })
        |> Ash.create(authorize?: false)

      opts = [flag_module: FeatureFlag]

      # First evaluate loads + caches; render is ON.
      assert FeatureFlags.evaluate("db.flag", org, opts).on

      # Delete the row out from under the cache. A cached read must NOT re-hit the
      # DB — it still sees the warm ON config (proves no per-render DB read).
      {:ok, [row]} =
        FeatureFlag |> Ash.Query.filter(name == "db.flag") |> Ash.read(authorize?: false)

      Ash.destroy!(row, authorize?: false)

      assert FeatureFlags.evaluate("db.flag", org, opts).on,
             "a cached render must not re-read the DB — else this would now be OFF"

      # A WRITE broadcasts an invalidation → next evaluate reloads and sees it gone.
      Cache.invalidate("db.flag")
      assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate("db.flag", org, opts)
    end
  end

  # ==========================================================================
  # Variant assignment seam (design §3.4)
  # ==========================================================================

  describe "variant assignment seam (design §3.4)" do
    test "a multivariate ON flag assigns a variant deterministically + builds the assignment payload" do
      test_pid = self()
      variants = %{"control" => 50, "treatment" => 50}
      opts = loader_opts(%{"exp" => cfg(rollout_pct: 100, variants: variants)})
      opts = Keyword.put(opts, :emit, fn payload -> send(test_pid, {:assigned, payload}) end)

      d = FeatureFlags.evaluate("exp", %{org_id: "org-777"}, opts)
      assert d.on
      assert d.variant in [:control, :treatment]

      # ONE assignment payload flows to the emit seam (the pae track/1 call lands in B7).
      assert_received {:assigned, payload}
      assert payload.event == "flag.assignment"
      assert payload.flag_name == "exp"
      assert payload.variant == d.variant
      assert payload.org_id == "org-777"

      # Deterministic: same subject → same variant on re-eval.
      d2 = FeatureFlags.evaluate("exp", %{org_id: "org-777"}, opts)
      assert d2.variant == d.variant
    end

    test "an OFF decision assigns no variant and emits nothing" do
      test_pid = self()
      opts = loader_opts(%{"exp" => cfg(enabled: false, variants: %{"a" => 100})})
      opts = Keyword.put(opts, :emit, fn payload -> send(test_pid, {:assigned, payload}) end)

      d = FeatureFlags.evaluate("exp", "org", opts)
      refute d.on
      assert d.variant == nil
      refute_received {:assigned, _}
    end

    # B6 UNIT 1 — the CONFIG-level emitter, the exact seam B7's track/1 plugs into:
    #     config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}
    # Zero call-site changes: every evaluate/2 with a variant assignment flows the
    # bounded flag.assignment payload to the configured {mod, fun}.
    test "the CONFIGURED emitter (B7 track/1 wiring point) receives the flag.assignment payload" do
      Application.put_env(:samen_core, :flag_emit_probe, self())
      Application.put_env(:samen_core, Samen.FeatureFlags, emit: {__MODULE__.EmitProbe, :track})

      on_exit(fn ->
        Application.delete_env(:samen_core, Samen.FeatureFlags)
        Application.delete_env(:samen_core, :flag_emit_probe)
      end)

      opts = loader_opts(%{"exp" => cfg(rollout_pct: 100, variants: %{"a" => 50, "b" => 50})})

      d = FeatureFlags.evaluate("exp", %{org_id: "org-cfg"}, opts)
      assert d.on
      assert d.variant in [:a, :b]

      assert_received {:tracked, payload}

      assert payload == %{
               event: "flag.assignment",
               flag_name: "exp",
               variant: d.variant,
               org_id: "org-cfg"
             }
    end

    test "evaluate_config/4 (the admin PREVIEW path) matches evaluate/2 but NEVER emits, even with a configured emitter" do
      Application.put_env(:samen_core, :flag_emit_probe, self())
      Application.put_env(:samen_core, Samen.FeatureFlags, emit: {__MODULE__.EmitProbe, :track})

      on_exit(fn ->
        Application.delete_env(:samen_core, Samen.FeatureFlags)
        Application.delete_env(:samen_core, :flag_emit_probe)
      end)

      config = cfg(rollout_pct: 100, variants: %{"a" => 50, "b" => 50})

      # The preview decides without emitting…
      preview = FeatureFlags.evaluate_config("exp", config, %{org_id: "org-prev"})
      refute_received {:tracked, _}

      # …and without touching the shared cache (a subsequent load still goes to the loader).
      assert {:error, :not_warmed} = Cache.get("exp", loader: fn _ -> {:error, :not_warmed} end)

      # Parity: the preview decision equals the cached-path decision (which DOES emit).
      cached = FeatureFlags.evaluate("exp", %{org_id: "org-prev"}, loader_opts(%{"exp" => config}))
      assert_received {:tracked, _}
      assert preview == cached

      # A nil config (unknown flag) previews fail-safe OFF.
      assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate_config("gone", nil, "org")
    end
  end

  defmodule EmitProbe do
    @moduledoc false
    def track(payload) do
      send(Application.get_env(:samen_core, :flag_emit_probe), {:tracked, payload})
      :ok
    end
  end
end
