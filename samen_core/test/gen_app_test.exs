defmodule Samen.Gen.AppTest do
  @moduledoc """
  Unit coverage for the `mix samen.gen.app` generator engine (T6.4). Exercises the pure
  spec derivation, the fail-closed validation rules (the generator's own guardrails), and
  the idempotent registry reservation — all WITHOUT touching the committed abbrev registry
  or scaffolding a real app (a temp registry file + a temp target dir keep it hermetic).

  The end-to-end "generated app passes its own gate" claim is covered by
  `priv/gen_app_gate_probe.exs` (the anti-tautology probe) and, in the workflow, by the
  T6.4 red path that scaffolds Widgetco and runs its ci.sh.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App, as: Gen

  defp spec(opts \\ []) do
    web? = Keyword.get(opts, :web, true)

    Gen.build_spec(
      module: opts[:module] || "Widgetco",
      prefix: opts[:prefix] || "wg",
      abbrev: opts[:abbrev] || "wid",
      target: opts[:target] || "/tmp/samen_gen_test_target",
      web: web?,
      api: Keyword.get(opts, :api, web?),
      deploy: Keyword.get(opts, :deploy, false),
      modules: Keyword.get(opts, :modules),
      port: Keyword.get(opts, :port, 4050)
    )
  end

  # The original T6.4 data-only emission — the `--headless` contract (AC-G4-10).
  @headless_paths [
    "mix.exs",
    ".formatter.exs",
    "config/config.exs",
    "config/dev.exs",
    "config/test.exs",
    "lib/<%= otp_app %>/application.ex",
    "lib/<%= otp_app %>/repo.ex",
    "lib/<%= otp_app %>/billing.ex",
    "lib/<%= otp_app %>/vertical.ex",
    "lib/<%= otp_app %>/aggregate.ex",
    "lib/<%= otp_app %>/approvals.ex",
    "priv/repo/migrations/20260705010000_ash_functions.exs",
    "priv/repo/migrations/20260705010100_oban.exs",
    "priv/repo/migrations/20260705010200_vault_tables.exs",
    "priv/repo/migrations/20260705010300_reveal_grants.exs",
    "priv/repo/migrations/20260705010400_erasure.exs",
    "priv/repo/migrations/20260705015000_catalog_tables.exs",
    "priv/repo/migrations/20260705020000_aud_event.exs",
    "priv/repo/migrations/20260705110000_migration_meta.exs",
    "priv/repo/migrations/20260706070000_tnt_field.exs",
    "priv/repo/migrations/20260706080000_tnt_object_record.exs",
    "priv/repo/migrations/20260709100000_app_resources.exs",
    "priv/repo/migrations/20260709150000_add_approvals.exs",
    "priv/ci_bootstrap.exs",
    "priv/anti_tautology_probe.exs",
    "test/test_helper.exs",
    "test/support/data_case.ex",
    "test/record_vault_test.exs",
    "ci.sh",
    ".gitignore",
    "README.md"
  ]

  @web_only_paths [
    "lib/<%= otp_app %>/primitives.ex",
    "lib/<%= otp_app %>/operator.ex",
    "priv/repo/migrations/20260714200000_mount_primitives_scope.exs",
    "priv/repo/migrations/20260714210000_mount_operator_scopes.exs",
    "lib/<%= otp_app %>_web/endpoint.ex",
    "lib/<%= otp_app %>_web/router.ex",
    "lib/<%= otp_app %>_web/layouts.ex",
    "lib/<%= otp_app %>_web/page_controller.ex",
    "lib/<%= otp_app %>_web/error_html.ex"
  ]

  # WS-D D3 (AC-G4-2): the api-only emissions. The PageLimitClamp is deliberately ABSENT
  # from this list — it is the canonical Samen.Web.Api.PageLimitClamp, inherited from the
  # samen_web dep, never re-emitted (design §3 drift guard).
  @api_only_paths [
    "lib/<%= otp_app %>_web/api/router.ex",
    "lib/<%= otp_app %>_web/api/endpoint.ex",
    "lib/<%= otp_app %>_web/api/key_auth_plug.ex",
    "test/support/api_case.ex",
    "test/record_api_test.exs"
  ]

  # WS-D D4 (AC-G4-4): the seed emissions — a Samen.Factory-backed seeds module, the
  # `<app>.seed` mix task, and the seed vault-routing red path. They ride with the full
  # (web + api) default set (the running product), so they appear in files(true, true).
  @seeds_paths [
    "lib/<%= otp_app %>/seeds.ex",
    "lib/mix/tasks/<%= otp_app %>.seed.ex",
    "test/seeds_vault_test.exs"
  ]

  # WS-D D10 (AC-G16-1/2/3): the fail-honest deploy emissions (ADR-024). Appended on top of
  # the web/api base; the `.gitignore` is a `[MOD]` swap (deploy variant), so it does NOT
  # appear in this appended list.
  @deploy_paths [
    "fly.toml",
    "lib/<%= otp_app %>/release.ex",
    "Dockerfile",
    "rel/env.sh.eex",
    "config/runtime.exs",
    "docs/runbooks/deploy.md"
  ]

  describe "build_spec/1 derivation" do
    test "derives otp_app, app_dir, resource, billing abbrevs, and aggregate abbrev" do
      s = spec()

      assert s.otp_app == :widgetco
      assert s.app_dir == "/tmp/samen_gen_test_target/widgetco"
      assert s.resource_module == "Widgetco.Vertical.Record"
      assert s.resource_table == "wid_record"

      assert s.billing_abbrevs == %{
               customer: "wgc",
               subscription: "wgs",
               plan: "wgl",
               price: "wgp",
               invoice: "wgi",
               payment: "wgy",
               usage: "wgu",
               entitlement: "wge",
               # WS-B / G7 (ADR-017): the subscription-movement ledger (`mov`).
               subscription_event: "wgv"
             }

      assert s.agg_abbrev == "wga"
      assert s.agg_table == "wga_record_count"
    end

    test "headless reserved_pairs covers the 9 billing + aggregate + authored + approvals abbrevs (12)" do
      pairs = Gen.reserved_pairs(spec(web: false))
      abbrevs = Enum.map(pairs, &elem(&1, 0))

      # 9 billing resources (incl. the `mov` subscription-movement ledger, ADR-017)
      # + aggregate + authored + approvals (T37h) = 12.
      assert length(pairs) == 12
      assert "wid" in abbrevs
      assert "wga" in abbrevs
      assert "wgc" in abbrevs
      assert "wgv" in abbrevs
      assert "wgz" in abbrevs
      assert {"wid", "Widgetco.Vertical.Record"} in pairs
      assert {"wga", "Widgetco.Aggregate.RecordCountBySegment"} in pairs
      assert {"wgc", "Widgetco.Billing.Customer"} in pairs
      assert {"wgv", "Widgetco.Billing.SubscriptionEvent"} in pairs
      assert {"wgz", "Widgetco.Approvals.Approval"} in pairs
    end

    test "web (default) reserved_pairs adds the 6 Primitives + 27 operator abbrevs (45)" do
      pairs = Gen.reserved_pairs(spec())
      abbrevs = Enum.map(pairs, &elem(&1, 0))

      # 12 headless (incl. T37h's approvals abbrev) + 6 Primitives + 27 operator
      # (Identity 11 [incl. ADR-035's Credential/AuthToken/Session/UserIdentity and
      # ADR-038 §6.4's LoginFailure, T109] + Billing 9 + Support 7) = 45.
      assert length(pairs) == 45
      assert length(Enum.uniq(abbrevs)) == 45

      # Primitives — <p1> + the blueprint suffix (the samen_web test-host convention).
      assert {"wnt", "Widgetco.Primitives.Notification"} in pairs
      assert {"wnp", "Widgetco.Primitives.NotificationPreference"} in pairs
      assert {"wff", "Widgetco.Primitives.FeatureFlag"} in pairs

      # Operator — <p1> + o/p/q + the per-resource letter (the driftwood convention).
      assert {"woo", "Widgetco.Operator.Org"} in pairs
      assert {"wou", "Widgetco.Operator.User"} in pairs
      # ADR-035 (T02x integration) — prefix-derived, NEVER the `crd`/`atk` literal
      # defaults (those are permanently owned by `hosts.demo` in the committed registry).
      assert {"woc", "Widgetco.Operator.Credential"} in pairs
      assert {"wot", "Widgetco.Operator.AuthToken"} in pairs
      # T06x (this integration pass) — prefix-derived, NEVER the `ses`/`uid` literal
      # defaults (also permanently owned by `hosts.demo` in the committed registry) —
      # the exact "ses" is registered to Demo.Identity.Session collision this fixes.
      assert {"wos", "Widgetco.Operator.Session"} in pairs
      assert {"woi", "Widgetco.Operator.UserIdentity"} in pairs
      # ADR-038 §6.4 (T109) — prefix-derived, NEVER the `dil` literal default
      # (permanently owned by `hosts.demo` in the committed registry).
      assert {"wol", "Widgetco.Operator.LoginFailure"} in pairs
      assert {"wpc", "Widgetco.Operator.Customer"} in pairs
      assert {"wpv", "Widgetco.Operator.SubscriptionEvent"} in pairs
      assert {"wqk", "Widgetco.Operator.Ticket"} in pairs
      assert {"wqs", "Widgetco.Operator.Csat"} in pairs
    end

    test "web derivation fails closed on an internal collision (prefix ending in o/p/q)" do
      # prefix "wp": the tenant Billing customer derives "wpc" AND the operator Billing
      # customer derives "wpc" (p1="w" + plane "p" + "c") — different owners, same abbrev.
      assert_raise ArgumentError, ~r/internal collisions/, fn ->
        Gen.validate_against!(spec(prefix: "wp"), %{})
      end
    end
  end

  describe "validate_against!/2 fail-closed rules" do
    @empty %{}

    test "green: a fresh, well-formed spec validates against an empty registry" do
      assert Gen.validate_against!(spec(), @empty) == :ok
    end

    test "red: a non-2-letter prefix is rejected" do
      assert_raise ArgumentError, ~r/prefix must be exactly 2 lowercase letters/, fn ->
        Gen.validate_against!(spec(prefix: "wgx"), @empty)
      end
    end

    test "red: a non-3-letter abbrev is rejected" do
      assert_raise ArgumentError, ~r/abbrev must be exactly 3 lowercase letters/, fn ->
        Gen.validate_against!(spec(abbrev: "wi"), @empty)
      end
    end

    test "red: an invalid module alias is rejected" do
      assert_raise ArgumentError, ~r/valid Elixir module alias/, fn ->
        Gen.validate_against!(spec(module: "widgetco"), @empty)
      end
    end

    test "red: internal collision (resource abbrev == derived aggregate abbrev) is rejected" do
      # prefix "nb" derives aggregate abbrev "nba"; the same abbrev on the resource collides.
      assert_raise ArgumentError, ~r/internal collisions/, fn ->
        Gen.validate_against!(spec(module: "Nb", prefix: "nb", abbrev: "nba"), @empty)
      end
    end

    test "red: an abbrev already owned by a DIFFERENT resource is rejected (permanence)" do
      registry = %{"wid" => "SomeoneElse.Resource"}

      assert_raise ArgumentError, ~r/already reserved to SomeoneElse.Resource/, fn ->
        Gen.validate_against!(spec(), registry)
      end
    end

    test "green: an abbrev already owned by the SAME resource is fine (idempotent re-run)" do
      registry = %{"wid" => "Widgetco.Vertical.Record"}
      assert Gen.validate_against!(spec(), registry) == :ok
    end
  end

  describe "reserve_abbrevs!/2 (idempotent, preserves $comment)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "samen_gen_reg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "abbrev_registry.json")

      File.write!(
        path,
        Jason.encode!(%{"$comment" => "PERMANENT registry.", "abbrevs" => %{"com" => "X.Y"}},
          pretty: true
        )
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: path}
    end

    test "reserves every abbrev into the app HOST namespace (ADR-023), preserving the global net + comment",
         %{path: path} do
      :ok = Gen.reserve_abbrevs!(spec(), path)

      decoded = path |> File.read!() |> Jason.decode!()

      assert decoded["$comment"] == "PERMANENT registry."
      # legacy global net (cross-host) byte-untouched — the allocator writes host namespaces only.
      assert decoded["abbrevs"]["com"] == "X.Y"
      refute Map.has_key?(decoded["abbrevs"], "wid")
      # all app abbrevs reserved to their owners inside host "widgetco".
      host = decoded["hosts"]["widgetco"]
      assert host["wid"] == "Widgetco.Vertical.Record"
      assert host["wga"] == "Widgetco.Aggregate.RecordCountBySegment"
      assert host["wgc"] == "Widgetco.Billing.Customer"
      assert host["wge"] == "Widgetco.Billing.Entitlement"
    end

    test "is idempotent: a second reservation is a no-op (no duplicates, no raise)",
         %{path: path} do
      :ok = Gen.reserve_abbrevs!(spec(), path)
      first = File.read!(path)

      :ok = Gen.reserve_abbrevs!(spec(), path)
      second = File.read!(path)

      assert first == second
    end

    test "refuses to hand a reserved abbrev to a different owner", %{path: path} do
      # Pre-seed "wid" to a different owner, then attempt reservation for Widgetco.
      File.write!(
        path,
        Jason.encode!(%{"abbrevs" => %{"wid" => "Intruder.Resource"}}, pretty: true)
      )

      assert_raise ArgumentError, ~r/already owned by Intruder.Resource/, fn ->
        Gen.reserve_abbrevs!(spec(), path)
      end
    end
  end

  describe "samen_core_rel_path/1" do
    test "a direct sibling resolves to ../samen_core" do
      s = spec(target: Gen.default_target())
      assert Gen.samen_core_rel_path(s) == "../samen_core"
    end

    test "a nested scratch parent resolves with extra .. segments" do
      s = spec(target: Path.join(Gen.default_target(), "_scratch"))
      assert Gen.samen_core_rel_path(s) == "../../samen_core"
    end
  end

  describe "render/2 template substitution" do
    test "replaces <%= key %> tokens and leaves unrelated text intact" do
      out = Gen.render("app=<%= otp_app %> mod=<%= module %> x<%= abbrev %>y", Gen.bindings(spec()))
      assert out == "app=widgetco mod=Widgetco xwidy"
    end
  end

  # ------------------------------------------------------------------ WS-D D2: --web
  describe "files/2 conditional emission (ADR-022)" do
    test "headless file set is EXACTLY the original data-only emission (AC-G4-10)" do
      assert Enum.map(Samen.Gen.Templates.files(false, false), &elem(&1, 0)) == @headless_paths
      # The files/1 convenience head follows the flag pairing (headless ⇒ no api).
      assert Samen.Gen.Templates.files(false) == Samen.Gen.Templates.files(false, false)
    end

    test "web-only file set = the headless paths + the 9 web emissions, in order (AC-G4-1)" do
      assert Enum.map(Samen.Gen.Templates.files(true, false), &elem(&1, 0)) ==
               @headless_paths ++ @web_only_paths
    end

    test "headless templates carry NO web dependency (byte-level red path)" do
      rendered =
        for {path, template} <- Samen.Gen.Templates.files(false, false), into: %{} do
          {path, Gen.render(template, Gen.bindings(spec(web: false)))}
        end

      refute rendered["mix.exs"] =~ "phoenix"
      refute rendered["mix.exs"] =~ "samen_web"
      refute rendered["mix.exs"] =~ "bandit"
      refute rendered["config/config.exs"] =~ "Endpoint"
      refute rendered["config/config.exs"] =~ "PubSub"
      refute rendered["lib/<%= otp_app %>/application.ex"] =~ "Endpoint"
    end

    test "web mix.exs/config/application gain the web deps + plane (AC-G4-1)" do
      b = Gen.bindings(spec())

      rendered =
        for {path, template} <- Samen.Gen.Templates.files(true, false), into: %{} do
          {Gen.render(path, b), Gen.render(template, b)}
        end

      mix_exs = rendered["mix.exs"]
      assert mix_exs =~ ~s({:samen_web, path:)
      assert mix_exs =~ ~s({:phoenix, "~> 1.7"})
      assert mix_exs =~ ~s({:phoenix_live_view, "~> 1.0"})
      assert mix_exs =~ ~s({:phoenix_html, "~> 4.1"})
      assert mix_exs =~ ~s({:bandit, "~> 1.0"})
      assert mix_exs =~ ~s({:phoenix_pubsub, "~> 2.1"})

      config = rendered["config/config.exs"]
      assert config =~ "config :widgetco, WidgetcoWeb.Endpoint"
      assert config =~ "adapter: Bandit.PhoenixAdapter"
      assert config =~ "pubsub_server: Widgetco.PubSub"
      assert config =~ "Widgetco.Primitives"
      assert config =~ "Widgetco.Operator"
      assert config =~ ~s(config :widgetco, :operator_org_id)
      # The Samen UI stylesheet is served from the samen_web dep (ADR-009).
      assert rendered["lib/widgetco_web/endpoint.ex"] =~
               ~s(from: {:samen_web, "priv/static/assets"})

      assert rendered["lib/widgetco_web/endpoint.ex"] =~ "samen_ui.css"

      app = rendered["lib/widgetco/application.ex"]
      assert app =~ "{Phoenix.PubSub, name: Widgetco.PubSub}"
      assert app =~ "WidgetcoWeb.Endpoint"
    end

    test "the emitted router mounts framework macros ONLY — zero authored LiveViews (AC-G4-1)" do
      b = Gen.bindings(spec())

      {_, router_t} =
        Enum.find(Samen.Gen.Templates.files(true, false), fn {p, _} -> p =~ "router" end)

      router = Gen.render(router_t, b)

      # The design's default mount set: the authored scope + notifications + the
      # operator plane (+ the session write), via Samen.Web.Router macros.
      assert router =~ "import Samen.Web.Router"
      assert router =~ "samen_module_routes(:billing, Widgetco.Billing, repo: Widgetco.Repo, labels: @current_org_labels)"
      assert router =~ "samen_notifications_routes(:notifications, Widgetco.Primitives,"
      assert router =~ "samen_operator_routes(Widgetco.Operator,"
      assert router =~ "samen_session_routes()"
      assert router =~ "flags_namespace: Widgetco.Primitives"

      # A9 (T10) — the FULL auth spine is emitted by DEFAULT: the ADR-035 §5 identity
      # surfaces (signup→verify→invite) + the A8 first-run onboarding wizard, over the
      # app's sole Identity mount (`Widgetco.Operator`), zero hand-edits.
      assert router =~ "samen_auth_routes(namespace: Widgetco.Operator, repo: Widgetco.Repo)"
      assert router =~ "samen_onboarding_routes(Widgetco.Operator, repo: Widgetco.Repo)"

      # Addendum 3 — the `:authn` prod-safety gate is wired on every tenant mount by
      # default, so a generated prod app never resolves an arbitrary org via `?org=`.
      assert router =~ "@current_org_labels %{authn: {:app_env, :widgetco, :auth_required?}}"

      # T117 (P9-F1 fix) — the OPERATOR control plane is conn-gated in prod. The generated
      # router declares the `:require_authenticated_operator` pipeline over `Samen.Web.AuthGate`
      # and pipes the operator scope through it (NOT the bare `:browser` pipeline), so a deployed
      # prod app redirects an anonymous `/operator/*` request to `/login`. Mirrors driftwood's
      # `plug(DriftwoodWeb.Auth)` house gate, scoped to the operator plane.
      assert router =~ "pipeline :require_authenticated_operator do"
      assert router =~ "plug(Samen.Web.AuthGate, otp_app: :widgetco)"
      assert router =~ "pipe_through([:browser, :require_authenticated_operator])"

      assert router =~ ~s{get("/healthz", PageController, :healthz)}
      # F1.2 — the readiness route sits alongside liveness (Repo/KMS/Oban probe).
      assert router =~ ~s{get("/readyz", PageController, :readyz)}

      # Zero authored LiveView modules: the ONLY module defined is the router itself,
      # and no live/2 route is declared outside the framework macros.
      assert Regex.scan(~r/defmodule /, router) |> length() == 1
      refute router =~ ~r/^\s+live\(/m
      refute router =~ "use Phoenix.LiveView"
    end

    test "the emitted layouts is a one-liner over the extracted Samen.Web.Layouts (ADR-022)" do
      b = Gen.bindings(spec())

      {_, layouts_t} =
        Enum.find(Samen.Gen.Templates.files(true, false), fn {p, _} -> p =~ "layouts" end)

      layouts = Gen.render(layouts_t, b)

      assert layouts =~ ~s(use Samen.Web.Layouts, title: "Widgetco — a Samen vertical")
      # The shell HTML is inherited, never re-emitted (the §3 drift guard).
      refute layouts =~ "<html"
      refute layouts =~ "inner_content"
    end

    test "web bindings derive the salts/port/paths deterministically" do
      b = Gen.bindings(spec())

      assert b["http_port"] == "4050"
      assert String.length(b["secret_key_base"]) >= 64
      assert b["secret_key_base"] =~ "widgetco_local_dogfood_secret_key_base_"
      assert b["p_nt"] == "wnt"
      assert b["o_org"] == "woo"
      assert b["o_sev"] == "wpv"
      assert b["o_csat"] == "wqs"

      # Headless bindings carry NO web keys (the substitution engine stays exact).
      hb = Gen.bindings(spec(web: false))
      refute Map.has_key?(hb, "http_port")
      refute Map.has_key?(hb, "samen_web_path")
    end

    test "samen_web_rel_path resolves the sibling samen_web like samen_core's" do
      s = spec(target: Gen.default_target())
      assert Gen.samen_web_rel_path(s) == "../samen_web"
    end
  end

  # ------------------------------------------------------------------ WS-D D3: --api
  describe "the api flag (WS-D D3, ADR-022)" do
    test "api? defaults to web? (ON with the web layer, OFF under --headless)" do
      assert spec().api? == true
      assert Gen.build_spec(
               module: "Widgetco",
               prefix: "wg",
               abbrev: "wid",
               target: "/tmp/samen_gen_test_target",
               web: false
             ).api? == false
    end

    test "red: api WITHOUT the web layer fails closed (the host router forwards /api/v1)" do
      assert_raise ArgumentError, ~r/--api requires the web layer/, fn ->
        Gen.validate_against!(spec(web: false, api: true), %{})
      end
    end

    test "red: files(false, true) has NO clause — an api-without-web file set cannot exist" do
      # `apply/3` keeps the deliberately-invalid call out of the compiler's static type
      # pass (which would flag the missing clause as a type warning under
      # --warnings-as-errors) while still proving the runtime fail-closed guarantee.
      assert_raise FunctionClauseError, fn ->
        apply(Samen.Gen.Templates, :files, [false, true])
      end
    end

    test "full file set = headless + web + the 5 api + the 3 seed emissions, in order (AC-G4-2/4)" do
      assert Enum.map(Samen.Gen.Templates.files(true, true), &elem(&1, 0)) ==
               @headless_paths ++ @web_only_paths ++ @api_only_paths ++ @seeds_paths

      # files/1 with web on defaults api on (the ADR-022 default pairing).
      assert Samen.Gen.Templates.files(true) == Samen.Gen.Templates.files(true, true)
    end

    test "web-only (--no-api) emits NO api file and no ash_json_api dep (red path)" do
      web_only = Samen.Gen.Templates.files(true, false)
      paths = Enum.map(web_only, &elem(&1, 0))

      for api_path <- @api_only_paths, do: refute(api_path in paths)
      # The seeds ride with the full running product (they anchor on the API's data);
      # the headless/web-only sets do NOT emit them.
      for seed_path <- @seeds_paths, do: refute(seed_path in paths)

      {_, mix_t} = Enum.find(web_only, fn {p, _} -> p == "mix.exs" end)
      refute Gen.render(mix_t, Gen.bindings(spec(api: false))) =~ "ash_json_api"

      {_, vertical_t} = Enum.find(web_only, fn {p, _} -> p =~ "vertical" end)
      refute Gen.render(vertical_t, Gen.bindings(spec(api: false))) =~ "json_api"
    end
  end

  # The full (web + api) file set rendered with the default Widgetco spec — the
  # D3 assertions below read individual files out of it. Module-level (defp is not
  # permitted inside `describe`).
  defp rendered_api_files do
    b = Gen.bindings(spec())

    for {path, template} <- Samen.Gen.Templates.files(true, true), into: %{} do
      {Gen.render(path, b), Gen.render(template, b)}
    end
  end

  describe "the api emission (WS-D D3 — deny-by-default allowlist + bounded read)" do
    test "mix.exs gains the ash_json_api dep (AC-G4-2)" do
      assert rendered_api_files()["mix.exs"] =~ ~s({:ash_json_api, "~> 1.7"})
    end

    test "the authored resource carries the DENY-BY-DEFAULT json_api allowlist + bounded :api_read (AC-G4-3)" do
      vertical = rendered_api_files()["lib/widgetco/vertical.ex"]

      # The AshJsonApi extensions (the demo Contact idiom).
      assert vertical =~ "extensions: [AshJsonApi.Domain]"
      assert vertical =~ "extensions: [AshJsonApi.Resource]"

      # The allowlist: EXACTLY the non-PII catalog fields.
      assert vertical =~ ~s{show_fields([:id, :name, :segment])}
      assert vertical =~ ~s{type("record")}

      # THE RED PATH (deny-by-default): the vault field `secret` lives ON the resource
      # (pii_attribute) but NOT on the allowlist; `org_id` likewise.
      [show_fields_line] =
        vertical |> String.split("\n") |> Enum.filter(&(&1 =~ "show_fields(["))

      refute show_fields_line =~ "secret"
      refute show_fields_line =~ "org_id"
      assert vertical =~ "pii_attribute(:secret, :string, vault: :pii_secret)"

      # F3.7 — the filter surface matches the serialization surface.
      assert vertical =~ "derive_filter?(false)"

      # The BOUNDED api_read the routes bind to (default_limit 50 / max_page_size 200).
      assert vertical =~ "read :api_read do"
      assert vertical =~ "default_limit: 50"
      assert vertical =~ "max_page_size: 200"
      assert vertical =~ "paginate_by_default?: true"
      assert vertical =~ ~s{base("/records")}
      assert vertical =~ "get(:api_read)"
      assert vertical =~ "index(:api_read)"
    end

    test "the api endpoint pipeline is KeyAuthPlug → the INHERITED PageLimitClamp → AshJsonApi router (AC-G4-2, §3 drift guard)" do
      files = rendered_api_files()
      endpoint = files["lib/widgetco_web/api/endpoint.ex"]

      assert endpoint =~ "use Plug.Builder"
      assert endpoint =~ "plug(WidgetcoWeb.Api.KeyAuthPlug)"
      assert endpoint =~ "plug(Samen.Web.Api.PageLimitClamp)"
      assert endpoint =~ "plug(WidgetcoWeb.Api.Router)"

      # Pipeline ORDER: auth → clamp → router.
      [auth_idx, clamp_idx, router_idx] =
        for probe <- [
              "plug(WidgetcoWeb.Api.KeyAuthPlug)",
              "plug(Samen.Web.Api.PageLimitClamp)",
              "plug(WidgetcoWeb.Api.Router)"
            ] do
          {idx, _} = :binary.match(endpoint, probe)
          idx
        end

      assert auth_idx < clamp_idx and clamp_idx < router_idx

      # §3 drift guard: the clamp is inherited from samen_web — NEVER re-emitted as a
      # local mirror (the demo mirror exists only because demo is samen_core-only).
      refute endpoint =~ "defmodule WidgetcoWeb.Api.PageLimitClamp"
      refute Map.has_key?(files, "lib/widgetco_web/api/page_limit_clamp.ex")

      router = files["lib/widgetco_web/api/router.ex"]
      assert router =~ "use AshJsonApi.Router,"
      assert router =~ "domains: [Widgetco.Vertical],"
      assert router =~ ~s{prefix: "/api/v1"}
    end

    test "the host router forwards /api/v1 to the api endpoint (the driftwood idiom)" do
      router = rendered_api_files()["lib/widgetco_web/router.ex"]
      assert router =~ ~s{forward("/api/v1", WidgetcoWeb.Api.Endpoint)}

      # Still zero authored LiveViews (the AC-G4-1 invariant holds under --api).
      assert Regex.scan(~r/defmodule /, router) |> length() == 1
      refute router =~ ~r/^\s+live\(/m
    end

    test "the KeyAuthPlug resolves keys off the operator Identity mount, fail closed" do
      plug = rendered_api_files()["lib/widgetco_web/api/key_auth_plug.ex"]

      assert plug =~ "Widgetco.Operator.ApiKey"
      assert plug =~ "Widgetco.Operator.Membership"
      assert plug =~ "token_digest == ^digest"
      assert plug =~ "is_nil(revoked_at)"
      # SHA-256 digest lookup — the raw key is never persisted or compared in clear.
      assert plug =~ ":crypto.hash(:sha256, raw)"
      # Fail closed: no valid key → no actor.
      assert plug =~ "_ -> conn"
    end

    test "ci.sh gains the api_contract step (18 steps) and README documents the API" do
      files = rendered_api_files()
      ci = files["ci.sh"]

      assert ci =~ "step 16/18: mix samen.verify.api_contract --version v1"
      assert ci =~ ~s{--snapshot "$APP_DIR/api_contract.v1.json"}
      assert ci =~ "step 17/18: mix test"
      assert ci =~ "step 18/18: anti-tautology probe"
      refute ci =~ "/17:"

      readme = files["README.md"]
      assert readme =~ "/api/v1"
      assert readme =~ "api_contract.v1.json"
    end

    test "the gen'd API red-path suite covers bounded/clamp/deny-by-default (AC-G4-3)" do
      files = rendered_api_files()
      api_test = files["test/record_api_test.exs"]

      # Bounded by default + clamped at the cap (the PageLimitClamp e2e pattern) — the
      # seed EXCEEDS the cap so both bounds are non-vacuous.
      assert api_test =~ "@seed 210"
      assert api_test =~ "length(data) == 50"
      assert api_test =~ "page[limit]=10000"
      assert api_test =~ "length(data) == 200"

      # THE RED PATH: the un-allowlisted vault field is absent from every payload,
      # including via ?fields=; positive controls keep it non-vacuous.
      assert api_test =~ ~s{refute Map.has_key?(attrs, "secret")}
      assert api_test =~ "fields[record]=secret"
      assert api_test =~ ~s{assert Map.has_key?(attrs, "name")}
      assert api_test =~ ~s{refute Map.has_key?(attrs, "org_id")}

      api_case = files["test/support/api_case.ex"]
      assert api_case =~ "Widgetco.Operator.ApiKey"
      assert api_case =~ "WidgetcoWeb.Api.KeyAuthPlug.digest(raw)"
      assert api_case =~ "WidgetcoWeb.Api.Endpoint.call"
    end
  end

  describe "the seeds emission (WS-D D4 — vault-aware via Samen.Factory, AC-G4-4)" do
    test "seeds.ex writes through Samen.Factory (the SampleData vault path), not raw Ash" do
      seeds = rendered_api_files()["lib/widgetco/seeds.ex"]

      # The load-bearing idiom: seeded PII routes through Samen.Factory.create!/3 (the
      # same guarded create action a real tenant write takes) — NOT a hand-rolled
      # Ash.Changeset that could skip the vault chokepoint.
      assert seeds =~ "Samen.Factory.create!"
      assert seeds =~ "Widgetco.Vertical.Record"
      # The 🔒 secret is passed as an ordinary attr; the create action vault-routes it.
      assert seeds =~ "secret:"
      assert seeds =~ "def run"
      # Anchored on the well-known operator org so the seeded rows are addressable.
      assert seeds =~ "operator_org_id" or seeds =~ ~s{@org_id}
    end

    test "the <app>.seed mix task wraps Seeds.run/0 after starting the app" do
      task = rendered_api_files()["lib/mix/tasks/widgetco.seed.ex"]

      assert task =~ "defmodule Mix.Tasks.Widgetco.Seed"
      assert task =~ ~s{@requirements ["app.start"]}
      assert task =~ "Widgetco.Seeds.run()"
    end

    test "the gen'd seed vault-routing red path scans raw rows for seeded plaintext (AC-G4-4)" do
      test_file = rendered_api_files()["test/seeds_vault_test.exs"]

      # Runs the seeds, then a raw-SQL scan of the physical vault column — the token must
      # be vt_*, and NO seeded plaintext may appear at rest (non-vacuous: it names the
      # exact seeded secrets, so a vault-bypassing seed would flip it to fail).
      assert test_file =~ "Widgetco.Seeds.run()"
      assert test_file =~ ~s{"SELECT pii_wid_secret FROM wid_record}
      assert test_file =~ ~s{String.starts_with?(raw, "vt_")}
      assert test_file =~ "refute raw == plaintext"
    end
  end

  describe "the observability wiring (WS-D D5 — un-forgettable db_statement, AC-G4-6)" do
    test "application.ex splices Samen.Observability.child_specs/1 into the repo plane" do
      # The running product wires observability via the framework helper (which OWNS the
      # db_statement: :disabled default), byte-matching the pawchart reference — NOT
      # hand-copied OpentelemetryEcto.setup calls.
      app = rendered_api_files()["lib/widgetco/application.ex"]

      assert app =~ "Samen.Observability.child_specs(:widgetco)"
      refute app =~ "OpentelemetryEcto.setup"
    end

    test "config.exs sets the un-forgettable db_statement: :disabled + lists otel as a DIRECT dep" do
      files = rendered_api_files()
      config = files["config/config.exs"]
      mix = files["mix.exs"]

      # The config the no_plaintext_pii LogTelemetry tier asserts (config-level check).
      assert config =~ "config :widgetco, :opentelemetry_ecto, db_statement: :disabled"

      # opentelemetry_ecto is a DIRECT dep so the tier (which reads Mix.Project.config
      # [:deps], not transitive apps) SEES the leak surface and arms the assertion —
      # this is what makes the D6 db_statement sabotage non-vacuous.
      assert mix =~ ~s({:opentelemetry_ecto, "~> 1.2"})
    end
  end

  # ------------------------------------------------------------------ WS-D D10: --deploy
  describe "the deploy flag (WS-D D10, ADR-024 — opt-in, fail-honest)" do
    test "deploy? defaults OFF (opt-in — AC-G16 / ADR-024 §2.6)" do
      assert spec().deploy? == false
      assert spec(deploy: true).deploy? == true
    end

    test "red: --deploy WITHOUT the web layer fails closed (runtime.exs/fly.toml need the endpoint)" do
      assert_raise ArgumentError, ~r/--deploy requires the web layer/, fn ->
        Gen.validate_against!(spec(web: false, deploy: true), %{})
      end
    end

    test "red: files(false, _, true) has NO clause — a deploy-without-web file set cannot exist" do
      # apply/3 keeps the deliberately-invalid call out of the compiler's static type pass.
      assert_raise FunctionClauseError, fn ->
        apply(Samen.Gen.Templates, :files, [false, false, true])
      end
    end

    test "full deploy set = headless + web + api + seeds + the 6 deploy emissions, in order (AC-G16-1)" do
      assert Enum.map(Samen.Gen.Templates.files(true, true, true), &elem(&1, 0)) ==
               @headless_paths ++ @web_only_paths ++ @api_only_paths ++ @seeds_paths ++
                 @deploy_paths

      # files/2 never emits the deploy layer (default OFF) — it equals files/3 with deploy? false.
      assert Samen.Gen.Templates.files(true, true) == Samen.Gen.Templates.files(true, true, false)
    end

    test "deploy on a --no-api web app appends the deploy files onto the web-only base" do
      paths = Enum.map(Samen.Gen.Templates.files(true, false, true), &elem(&1, 0))
      assert paths == @headless_paths ++ @web_only_paths ++ @deploy_paths
    end

    test "the default set (no --deploy) emits NONE of the deploy files (red path)" do
      paths = Enum.map(Samen.Gen.Templates.files(true, true, false), &elem(&1, 0))
      for deploy_path <- @deploy_paths, do: refute(deploy_path in paths)
    end
  end

  # The full deploy file set rendered with the default Widgetco spec (deploy ON).
  defp rendered_deploy_files do
    b = Gen.bindings(spec(deploy: true))

    for {path, template} <- Samen.Gen.Templates.files(true, true, true), into: %{} do
      {Gen.render(path, b), Gen.render(template, b)}
    end
  end

  describe "config/runtime.exs is fail-closed (WS-D D10 / AC-G16-2)" do
    setup do
      %{runtime: rendered_deploy_files()["config/runtime.exs"]}
    end

    test "reads every required secret + the KMS env, gated to :prod", %{runtime: rt} do
      assert rt =~ "if config_env() == :prod do"

      for var <- ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST SAMEN_KMS_KEY_ID SAMEN_KMS_REGION) do
        assert rt =~ var, "runtime.exs must read the required secret #{var}"
      end
    end

    test "each secret is read through the fail-closed fetch_secret! (raises named on missing)",
         %{runtime: rt} do
      # The reader raises a NAMED error (the missing var interpolated) rather than a
      # silent insecure boot — the ADR-024 boot-honest guarantee.
      assert rt =~ "fetch_secret! = fn var, hint ->"
      assert rt =~ ~s|raise|
      assert rt =~ "is missing the required secret environment variable \#{var}"
      # An EMPTY secret is treated as missing (also fail-closed).
      assert rt =~ "is set but EMPTY"

      # Every required secret is routed through fetch_secret! (no bare System.get_env
      # fallback for a required one): the var name appears as the first arg of a
      # `fetch_secret!.(` call (indentation-agnostic).
      for var <- ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST SAMEN_KMS_KEY_ID SAMEN_KMS_REGION) do
        assert Regex.match?(~r/fetch_secret!\.\(\s*"#{var}"/, rt),
               "required secret #{var} must be read through the fail-closed fetch_secret!"
      end
    end

    test "wires the prod KMS adapter from the SAMEN_KMS_* env (vault keystore)", %{runtime: rt} do
      assert rt =~ "config :samen_core, :kms_adapter, Samen.Kms.AwsKmsDynamo"
      assert rt =~ "config :samen_core, :aws_kms_dynamo_enabled, true"
    end

    test "NO insecure dev fallback (empty password / localhost) in the prod runtime", %{runtime: rt} do
      refute rt =~ ~s(password: "")
      refute rt =~ ~s(hostname: "localhost")
    end
  end

  describe "fly.toml + Dockerfile + release (WS-D D10 / AC-G16-1)" do
    setup do
      %{files: rendered_deploy_files()}
    end

    test "fly.toml binds the endpoint port, the /readyz check, and a migrate release_command",
         %{files: f} do
      fly = f["fly.toml"]
      # The endpoint port the web plane owns (default 4050).
      assert fly =~ "internal_port = 4050"
      assert fly =~ "[http_service]"
      assert fly =~ "[[http_service.checks]]"
      # F1.2: the traffic gate hits the READINESS probe, not the static-200 liveness route —
      # a machine whose Postgres/KMS/Oban is down is drained, not sent traffic it can only 500.
      assert fly =~ ~s(path = "/readyz")
      refute fly =~ ~s(path = "/healthz")
      assert fly =~ "release_command"
      assert fly =~ "Widgetco.Release.migrate"
    end

    test "fly.toml is structurally-valid TOML (parses into sections + key=value pairs)",
         %{files: f} do
      # A focused structural validator (no TOML dep): every non-blank, non-comment line is
      # either a `[section]` / `[[array]]` header or a `key = value` pair; brackets balance.
      # This is the ADR-024 proof bound ("fly.toml parses") without a live `fly` call.
      assert toml_structurally_valid?(f["fly.toml"])
    end

    test "the release module runs migrations without Mix (release-safe)", %{files: f} do
      rel = f["lib/widgetco/release.ex"]
      assert rel =~ "defmodule Widgetco.Release do"
      assert rel =~ "def migrate do"
      assert rel =~ "Ecto.Migrator"
      # No Mix at runtime.
      refute rel =~ "Mix."
    end

    test "the Dockerfile is a two-stage mix release build over the monorepo context", %{files: f} do
      docker = f["Dockerfile"]
      assert docker =~ "AS builder"
      assert docker =~ "mix release"
      assert docker =~ "COPY samen_core"
      assert docker =~ "COPY samen_web"
      assert docker =~ ~s(CMD ["/app/bin/widgetco", "start"])
    end
  end

  describe "docs/runbooks/deploy.md operator-TODO block (WS-D D10 / AC-G16-3)" do
    setup do
      %{runbook: rendered_deploy_files()["docs/runbooks/deploy.md"]}
    end

    test "has an explicit Operator TODO section", %{runbook: rb} do
      assert rb =~ "## Operator TODO"
    end

    test "the Operator TODO names all four human prerequisites", %{runbook: rb} do
      todo = rb |> String.split("## Operator TODO") |> List.last()
      # Fly account, Neon project, KMS keys, OTLP exporter — the honest carries.
      assert todo =~ ~r/Fly account/i
      assert todo =~ ~r/Neon project/i
      assert todo =~ ~r/KMS key/i
      assert todo =~ ~r/OTLP exporter/i
    end

    test "documents Neon branch-per-env + the secrets checklist (incl. KMS + SECRET_KEY_BASE)",
         %{runbook: rb} do
      assert rb =~ ~r/branch-per-env/i
      assert rb =~ "SECRET_KEY_BASE"
      assert rb =~ "SAMEN_KMS_KEY_ID"
      assert rb =~ "mix phx.gen.secret"
    end

    test "is honest — no aspirational turnkey 'just run fly deploy'", %{runbook: rb} do
      refute rb =~ ~r/just run `fly deploy`/i
      assert rb =~ "fail-honest"
    end
  end

  # ------------------------------------------------------------------ WS-E: --modules
  describe "the --modules surface selection (WS-E)" do
    defp rendered_router(spec) do
      {_, t} = Enum.find(Samen.Gen.Templates.files(true, true, false), fn {p, _} -> p =~ "router" end)
      Gen.render(t, Gen.bindings(spec))
    end

    test "default: no --modules is byte-safe (root route + metrics tail unchanged, no menu)" do
      s = spec()
      assert s.modules == []

      b = Gen.bindings(s)
      assert b["module_mounts"] == ""
      assert b["menu_nav_items"] == ""
      assert b["root_route"] == ~s{get("/", PageController, :index)}

      router = rendered_router(s)
      assert router =~ "\n    get(\"/\", PageController, :index)\n"
      assert router =~ "\n    samen_metrics_route(name: :widgetco_prometheus)\n  end\n"
      refute router =~ "HomeLive"
      refute router =~ "samen_files_routes"
      refute router =~ "--modules"
    end

    test "normalizes a comma-separated string into known surface atoms (order-stable, unique)" do
      s = spec(modules: "settings, files ,files,search")
      assert s.modules == [:settings, :files, :search]
    end

    test "validate: an unknown surface fails closed" do
      s = spec(modules: "files,frobnicate")
      assert_raise ArgumentError, ~r/unknown surface/, fn -> Gen.validate_against!(s, %{}) end
    end

    test "validate: --modules without the web layer fails closed" do
      s = spec(web: false, api: false, modules: "files")
      assert_raise ArgumentError, ~r/--modules requires the web layer/, fn ->
        Gen.validate_against!(s, %{})
      end
    end

    test "mounts the mountable surfaces over the app's existing mounts + swaps / to HomeLive" do
      router = rendered_router(spec(modules: "files,search,csv,settings"))

      # Each mountable surface carries the `@current_org_labels` (:authn prod gate) seam;
      # settings ALSO opts into `spine_totp: true` so its Security surface exposes the
      # real TOTP-enroll route (Addenda 2 & 3).
      assert router =~ "samen_files_routes(:files, Widgetco.Primitives, repo: Widgetco.Repo, labels: @current_org_labels)"
      assert router =~ "samen_search_routes(:search, Widgetco.Primitives, repo: Widgetco.Repo, labels: @current_org_labels)"
      assert router =~ "samen_csv_routes(:csv, Widgetco.Vertical, repo: Widgetco.Repo, labels: @current_org_labels)"
      assert router =~ "samen_settings_routes(:settings, Widgetco.Operator,"
      assert router =~ "spine_totp: true"
      # The landing swaps to the Samen.UI menu LiveView (bare name — the scope aliases it).
      assert router =~ ~s{live("/", HomeLive)}
      refute router =~ ~s{get("/", PageController, :index)}
    end

    test "chat is documented-with-prerequisite, never half-mounted" do
      router = rendered_router(spec(modules: "chat,files"))

      # files still mounts for real...
      assert router =~ "samen_files_routes(:files, Widgetco.Primitives"
      # ...but chat is a prerequisite COMMENT, not a samen_chat_routes mount.
      assert router =~ "chat requested but NOT auto-mounted"
      assert router =~ "docs/guides/generators.md"
      refute router =~ ~r/^\s*samen_chat_routes\(/m
    end

    test "a chat-only request mounts nothing and ships no menu landing (honest)" do
      s = spec(modules: "chat")
      router = rendered_router(s)

      assert router =~ "chat requested but NOT auto-mounted"
      # No mountable surface → the landing stays the plain PageController index.
      assert router =~ ~s{get("/", PageController, :index)}
      refute router =~ "HomeLive"
      assert Gen.bindings(s)["menu_nav_items"] == ""
    end

    test "the HomeLive menu leans on the Samen.UI kit and lists the mounted surfaces" do
      s = spec(modules: "files,search,settings")
      home = Gen.render(Samen.Gen.Templates.home_live_ex(), Gen.bindings(s))

      assert home =~ "defmodule WidgetcoWeb.HomeLive do"
      assert home =~ "import Samen.UI"
      assert home =~ "<.app_shell>"
      assert home =~ "<.module_nav"
      assert home =~ ~s{<.nav_group label="Product">}
      assert home =~ ~s{<.nav_item label="Files"}
      assert home =~ ~s{<.nav_item label="Search"}
      assert home =~ ~s{<.nav_item label="Settings"}
      # No CSV was selected here — the menu lists only what is mounted.
      refute home =~ ~s{<.nav_item label="CSV import"}
    end
  end

  # A minimal structural TOML validator for the deploy proof bound (no TOML dep in
  # samen_core). Asserts: balanced brackets on header lines; every non-blank, non-comment
  # line is a `[section]` / `[[array]]` header OR a `key = value` pair. Multi-line values
  # aren't emitted by the fly.toml template, so a line-oriented check is sufficient + honest.
  defp toml_structurally_valid?(toml) do
    toml
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.all?(fn line ->
      header? =
        (String.starts_with?(line, "[") and String.ends_with?(line, "]")) and
          balanced_brackets?(line)

      kv? = Regex.match?(~r/\A\S+\s*=\s*.+\z/, line)

      header? or kv?
    end)
  end

  defp balanced_brackets?(line) do
    opens = line |> String.graphemes() |> Enum.count(&(&1 == "["))
    closes = line |> String.graphemes() |> Enum.count(&(&1 == "]"))
    opens == closes and opens > 0
  end
end
