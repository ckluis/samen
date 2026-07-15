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
      port: Keyword.get(opts, :port, 4050)
    )
  end

  # The original T6.4 data-only emission — the `--headless` contract (AC-G4-10).
  @headless_paths [
    "mix.exs",
    "config/config.exs",
    "config/dev.exs",
    "config/test.exs",
    "lib/<%= otp_app %>/application.ex",
    "lib/<%= otp_app %>/repo.ex",
    "lib/<%= otp_app %>/billing.ex",
    "lib/<%= otp_app %>/vertical.ex",
    "lib/<%= otp_app %>/aggregate.ex",
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

    test "headless reserved_pairs covers the 9 billing + aggregate + authored abbrevs (11)" do
      pairs = Gen.reserved_pairs(spec(web: false))
      abbrevs = Enum.map(pairs, &elem(&1, 0))

      # 9 billing resources (incl. the `mov` subscription-movement ledger, ADR-017)
      # + aggregate + authored = 11.
      assert length(pairs) == 11
      assert "wid" in abbrevs
      assert "wga" in abbrevs
      assert "wgc" in abbrevs
      assert "wgv" in abbrevs
      assert {"wid", "Widgetco.Vertical.Record"} in pairs
      assert {"wga", "Widgetco.Aggregate.RecordCountBySegment"} in pairs
      assert {"wgc", "Widgetco.Billing.Customer"} in pairs
      assert {"wgv", "Widgetco.Billing.SubscriptionEvent"} in pairs
    end

    test "web (default) reserved_pairs adds the 6 Primitives + 22 operator abbrevs (39)" do
      pairs = Gen.reserved_pairs(spec())
      abbrevs = Enum.map(pairs, &elem(&1, 0))

      # 11 headless + 6 Primitives + 22 operator (Identity 6 + Billing 9 + Support 7) = 39.
      assert length(pairs) == 39
      assert length(Enum.uniq(abbrevs)) == 39

      # Primitives — <p1> + the blueprint suffix (the samen_web test-host convention).
      assert {"wnt", "Widgetco.Primitives.Notification"} in pairs
      assert {"wnp", "Widgetco.Primitives.NotificationPreference"} in pairs
      assert {"wff", "Widgetco.Primitives.FeatureFlag"} in pairs

      # Operator — <p1> + o/p/q + the per-resource letter (the driftwood convention).
      assert {"woo", "Widgetco.Operator.Org"} in pairs
      assert {"wou", "Widgetco.Operator.User"} in pairs
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

    test "appends every reserved abbrev and preserves the pre-existing rows + comment",
         %{path: path} do
      :ok = Gen.reserve_abbrevs!(spec(), path)

      decoded = path |> File.read!() |> Jason.decode!()

      assert decoded["$comment"] == "PERMANENT registry."
      # pre-existing row preserved
      assert decoded["abbrevs"]["com"] == "X.Y"
      # all 10 app abbrevs reserved to their owners
      assert decoded["abbrevs"]["wid"] == "Widgetco.Vertical.Record"
      assert decoded["abbrevs"]["wga"] == "Widgetco.Aggregate.RecordCountBySegment"
      assert decoded["abbrevs"]["wgc"] == "Widgetco.Billing.Customer"
      assert decoded["abbrevs"]["wge"] == "Widgetco.Billing.Entitlement"
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
      assert router =~ "samen_module_routes(:billing, Widgetco.Billing, repo: Widgetco.Repo)"
      assert router =~ "samen_notifications_routes(:notifications, Widgetco.Primitives,"
      assert router =~ "samen_operator_routes(Widgetco.Operator,"
      assert router =~ "samen_session_routes()"
      assert router =~ "flags_namespace: Widgetco.Primitives"
      assert router =~ ~s{get("/healthz", PageController, :healthz)}

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

    test "full file set = headless + web + the 5 api emissions, in order (AC-G4-2)" do
      assert Enum.map(Samen.Gen.Templates.files(true, true), &elem(&1, 0)) ==
               @headless_paths ++ @web_only_paths ++ @api_only_paths

      # files/1 with web on defaults api on (the ADR-022 default pairing).
      assert Samen.Gen.Templates.files(true) == Samen.Gen.Templates.files(true, true)
    end

    test "web-only (--no-api) emits NO api file and no ash_json_api dep (red path)" do
      web_only = Samen.Gen.Templates.files(true, false)
      paths = Enum.map(web_only, &elem(&1, 0))

      for api_path <- @api_only_paths, do: refute(api_path in paths)

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
end
