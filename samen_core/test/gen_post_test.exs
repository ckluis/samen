defmodule Samen.Gen.PostTest do
  @moduledoc """
  Unit coverage for the POST-APP generator engine (`Samen.Gen.Post`; WS-D D7a —
  `mix samen.gen.scope` / `mix samen.gen.resource`). Exercises the pure spec derivation,
  the fail-closed validation rules (permanence / collision / missing-scope), the
  format-agnostic `:ash_domains` registration, the resource-into-domain wiring, and the
  emitted-file set — all WITHOUT touching the committed abbrev registry or requiring
  Postgres (a temp app dir + a passed-in registry map keep it hermetic).

  The end-to-end "gen'd second scope+resource passes the full ci.sh with the four G26
  red-path files green + a red-path-mechanism sabotage flips one" claim is covered by
  `priv/gen_post_probe.exs` (the non-vacuity probe), run by the gen_app tier.
  """
  use ExUnit.Case, async: true

  alias Samen.CatalogMeaning
  alias Samen.Gen.App
  alias Samen.Gen.Post

  @description "A configurable widget a team offers, with a status and one vault-routed value."

  # A minimal fake generated-app tree in a temp dir: mix.exs (identity) + config
  # (both :ash_domains lists) + priv/repo/migrations. `web?` toggles single-line vs.
  # multi-line list form so the registration is proven against BOTH.
  defp fake_app!(web? \\ true) do
    dir = Path.join(System.tmp_dir!(), "gen_post_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))
    File.mkdir_p!(Path.join(dir, "lib/widgetco"))
    File.mkdir_p!(Path.join(dir, "priv/repo/migrations"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Widgetco.MixProject do
      use Mix.Project
      def project, do: [app: :widgetco]
      def application, do: [mod: {Widgetco.Application, []}]
    end
    """)

    own_list =
      if web? do
        "ash_domains: [\n    Widgetco.Billing,\n    Widgetco.Vertical,\n    Widgetco.Aggregate,\n    Widgetco.Primitives,\n    Widgetco.Operator\n  ]"
      else
        "ash_domains: [Widgetco.Billing, Widgetco.Vertical, Widgetco.Aggregate]"
      end

    core_list =
      if web? do
        "config :samen_core, :ash_domains, [\n  Widgetco.Billing,\n  Widgetco.Vertical,\n  Widgetco.Aggregate,\n  Widgetco.Primitives,\n  Widgetco.Operator\n]"
      else
        "config :samen_core, :ash_domains, [\n  Widgetco.Billing,\n  Widgetco.Vertical,\n  Widgetco.Aggregate\n]"
      end

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config

    config :widgetco,
      ecto_repos: [Widgetco.Repo],
      #{own_list}

    #{core_list}
    """)

    # A couple of existing substrate migrations so next_migration_ts sorts after them.
    File.write!(Path.join(dir, "priv/repo/migrations/20260705010000_ash_functions.exs"), "")
    File.write!(Path.join(dir, "priv/repo/migrations/20260709100000_app_resources.exs"), "")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # ---------------------------------------------------------------------------
  describe "read_app_identity!/1" do
    test "reads {app_module, otp_app} from mix.exs" do
      dir = fake_app!()
      assert {"Widgetco", :widgetco} = Post.read_app_identity!(dir)
    end

    test "raises on a non-app dir" do
      assert_raise ArgumentError, ~r/no mix.exs/, fn ->
        Post.read_app_identity!(System.tmp_dir!() <> "/nope_#{System.unique_integer()}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "build_scope_spec/1 + validate_scope!/1" do
    test "derives the scope module and validates a fresh scope" do
      dir = fake_app!()
      s = Post.build_scope_spec(app_dir: dir, scope: "Crm")
      assert s.scope_module == "Widgetco.Crm"
      assert s.otp_app == :widgetco
      assert Post.validate_scope!(s) == :ok
    end

    test "red: a bad scope alias is rejected" do
      dir = fake_app!()
      s = Post.build_scope_spec(app_dir: dir, scope: "crm")
      assert_raise ArgumentError, ~r/valid Elixir module alias/, fn -> Post.validate_scope!(s) end
    end

    test "red: an already-existing scope is refused (no overwrite)" do
      dir = fake_app!()
      s = Post.build_scope_spec(app_dir: dir, scope: "Crm")
      Post.write_scope!(s)
      assert_raise ArgumentError, ~r/already exists/, fn -> Post.validate_scope!(s) end
    end
  end

  describe "the next-step hint names the required --description" do
    test "RED: the scope task's success message and the emitted scope moduledoc show the CURRENT gen.resource shape" do
      dir = fake_app!()

      out =
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Samen.Gen.Scope.run(~w(--scope Crm --app-dir #{dir})) end)

      shape = ~S|--resource <Name> --abbrev <abc> --description "<what it is>"|
      assert out =~ shape
      assert File.read!(Path.join(dir, "lib/widgetco/crm.ex")) =~ shape
    end
  end

  # ---------------------------------------------------------------------------
  describe "write_scope!/1 registers the domain in BOTH :ash_domains lists" do
    for web? <- [true, false] do
      test "registers in both lists (web?=#{web?})" do
        dir = fake_app!(unquote(web?))
        s = Post.build_scope_spec(app_dir: dir, scope: "Crm")
        Post.write_scope!(s)

        cfg = File.read!(Path.join(dir, "config/config.exs"))
        # The new domain is the last element of BOTH lists.
        assert cfg =~ ~r/ash_domains:\s*\[[^\]]*Widgetco\.Crm[^\]]*\]/s
        assert cfg =~ ~r/:ash_domains,\s*\[[^\]]*Widgetco\.Crm[^\]]*\]/s
        # The empty scope domain file exists.
        assert File.exists?(Path.join(dir, "lib/widgetco/crm.ex"))
        assert File.read!(Path.join(dir, "lib/widgetco/crm.ex")) =~ "use Ash.Domain"
      end
    end

    test "registration is idempotent — a domain already present is not double-added" do
      dir = fake_app!()
      s = Post.build_scope_spec(app_dir: dir, scope: "Crm")
      Post.write_scope!(s)
      cfg1 = File.read!(Path.join(dir, "config/config.exs"))

      # Re-run the registration path (write_scope! validates existence separately, so call
      # the registration by writing again after removing the scope file).
      File.rm!(Path.join(dir, "lib/widgetco/crm.ex"))
      Post.write_scope!(s)
      cfg2 = File.read!(Path.join(dir, "config/config.exs"))

      assert cfg1 == cfg2
      # Exactly two occurrences of Widgetco.Crm (one per list), not four.
      assert length(Regex.scan(~r/Widgetco\.Crm\b/, cfg2)) == 2
    end
  end

  # ---------------------------------------------------------------------------
  describe "build_resource_spec/1 derivation" do
    test "derives module, table, test stem, and a monotonic migration ts" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      assert r.resource_module == "Widgetco.Crm.Widget"
      assert r.table == "wdg_widget"
      assert Post.test_stem(r) == "crm_widget"
      # One past the latest existing migration (20260709100000).
      assert r.migration_ts == "20260709100001"
    end

    test "field_type defaults to \"string\" (byte-identical to pre-T15 output)" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      assert r.field_type == "string"
      assert Post.resource_bindings(r)["field_ash_type"] == ":string"
    end
  end

  # ---------------------------------------------------------------------------
  # ADR-036 H7 (T15) — the `--field-type` full type menu (Samen.Gen.FieldTypeMenu).
  # The end-to-end "a resource generated with every menu type compiles and passes
  # its generated tests" claim is covered by `priv/gen_resource_type_menu_probe.exs`
  # (done-criterion 2); this describe block is the pure, hermetic unit coverage of
  # the spec-derivation + binding + fail-closed-validation seam.
  # ---------------------------------------------------------------------------
  describe "--field-type (ADR-036 H7/T15 type menu)" do
    setup do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      {:ok, dir: dir}
    end

    test "the menu has exactly the ten ADR-036 kinds" do
      assert Samen.Gen.FieldTypeMenu.menu() == ~w(
        string money percent score duration priority url email phone address
      )
    end

    test "every menu entry derives a valid spec + non-empty bindings", %{dir: dir} do
      for field_type <- Samen.Gen.FieldTypeMenu.menu() do
        r =
          Post.build_resource_spec(
            app_dir: dir,
            scope: "Crm",
            resource: "Widget",
            abbrev: "wdg",
            description: @description,
            field_type: field_type
          )

        assert r.field_type == field_type
        assert Post.validate_resource!(r, %{}) == :ok

        b = Post.resource_bindings(r)
        assert b["field_ash_type"] == Samen.Gen.FieldTypeMenu.ash_type(field_type)
        assert is_binary(b["field_dynamic_sample"]) and b["field_dynamic_sample"] != ""
        assert is_binary(b["field_vault_sample"]) and b["field_vault_sample"] != ""
        assert is_binary(b["field_vault_plaintext"]) and b["field_vault_plaintext"] != ""
        # The vault_routing_test plaintext-hunt marker must be a genuine substring of
        # what vault_sample/2 actually writes, or the emitted test would be vacuous.
        assert b["field_vault_sample"] =~ b["field_vault_plaintext"]
      end
    end

    test "red: an unknown --field-type is refused (closed-world, fail-closed)", %{dir: dir} do
      r =
        Post.build_resource_spec(
          app_dir: dir,
          scope: "Crm",
          resource: "Widget",
          abbrev: "wdg",
          description: @description,
          field_type: "geopoint"
        )

      assert_raise ArgumentError, ~r/--field-type must be one of/, fn ->
        Post.validate_resource!(r, %{})
      end
    end

    test "write_resource!/1 with field_type: \"money\" emits the Money pii_attribute + type-valid samples",
         %{dir: dir} do
      r =
        Post.build_resource_spec(
          app_dir: dir,
          scope: "Crm",
          resource: "Widget",
          abbrev: "wdg",
          description: @description,
          field_type: "money"
        )

      Post.validate_resource!(r, %{})
      Post.write_resource!(r)

      resource_src = File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))
      assert resource_src =~ "pii_attribute(:secret, Samen.Type.Money,\n      vault: :pii_secret,"

      policy = File.read!(Path.join(dir, "test/crm_widget_policy_matrix_test.exs"))
      assert policy =~ ~s(secret: "USD 12.34")
      refute policy =~ "SECRET-wdg-"

      rbac = File.read!(Path.join(dir, "test/crm_widget_rbac_red_path_test.exs"))
      assert rbac =~ ~s(secret: "USD 12.34")

      vault = File.read!(Path.join(dir, "test/crm_widget_vault_routing_test.exs"))
      assert vault =~ ~s(secret: "EUR 500123.87")
      assert vault =~ ~s(plaintexts: ["EUR 500123.87"])

      # attempt-2 regression guard: Money is SCALAR — the physical vault column
      # keeps the pii_ prefix (matches MaterializePii's scalar routing, D3).
      migration_file = Path.join(dir, "priv/repo/migrations/#{r.migration_ts}_add_widget.exs")
      migration_src = File.read!(migration_file)
      assert migration_src =~ "add(:pii_wdg_secret, :text)"
      refute migration_src =~ "add(:wdg_secret, :text)"
    end

    test "write_resource!/1 with field_type: \"address\" emits a map-literal sample (not a quoted string)",
         %{dir: dir} do
      r =
        Post.build_resource_spec(
          app_dir: dir,
          scope: "Crm",
          resource: "Widget",
          abbrev: "wdg",
          description: @description,
          field_type: "address"
        )

      Post.validate_resource!(r, %{})
      Post.write_resource!(r)

      resource_src = File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))
      assert resource_src =~ "pii_attribute(:secret, Samen.Type.Address,\n      vault: :pii_secret,"

      policy = File.read!(Path.join(dir, "test/crm_widget_policy_matrix_test.exs"))
      assert policy =~ ~s(secret: %{line1: "123 Test St",)

      vault = File.read!(Path.join(dir, "test/crm_widget_vault_routing_test.exs"))
      assert vault =~ ~s(secret: %{line1: "999 Vault Ave",)
      assert vault =~ ~s(plaintexts: ["999 Vault Ave"])

      # attempt-2 REGRESSION GUARD (the T15 attempt-1 defect a concurrent-task
      # abbrev-collision fix finally let `gen_resource_type_menu_probe.exs`
      # reach): Address is COMPOSITE — Samen.Transformers.MaterializePii routes
      # it with NO `pii_` column prefix (D4). The migration must create the
      # SAME physical column the resource actually materializes to, or
      # `mix samen.verify.catalog_parity` fails on the mismatch.
      migration_file = Path.join(dir, "priv/repo/migrations/#{r.migration_ts}_add_widget.exs")
      migration_src = File.read!(migration_file)
      assert migration_src =~ "add(:wdg_secret, :text)"
      refute migration_src =~ "add(:pii_wdg_secret, :text)"
    end

    # A distinct, valid 3-letter abbrev per menu entry (this describe block's own
    # `dir` fixture starts with an empty abbrev history — no collision risk).
    @menu_abbrevs %{
      "string" => "wds",
      "money" => "wdm",
      "percent" => "wdp",
      "score" => "wdc",
      "duration" => "wdu",
      "priority" => "wdy",
      "url" => "wdl",
      "email" => "wde",
      "phone" => "wdh",
      "address" => "wda"
    }

    test "the migration's vault column name matches Samen.Transformers.MaterializePii's routing for EVERY menu entry",
         %{dir: dir} do
      for field_type <- Samen.Gen.FieldTypeMenu.menu() do
        resource_name = "Widget#{Macro.camelize(field_type)}"
        abbrev = Map.fetch!(@menu_abbrevs, field_type)

        r =
          Post.build_resource_spec(
            app_dir: dir,
            scope: "Crm",
            resource: resource_name,
            abbrev: abbrev,
            description: @description,
            field_type: field_type
          )

        Post.validate_resource!(r, %{})
        Post.write_resource!(r)

        migration_file =
          Path.join(
            dir,
            "priv/repo/migrations/#{r.migration_ts}_add_#{Macro.underscore(resource_name)}.exs"
          )

        migration_src = File.read!(migration_file)
        expected_column = Samen.Gen.FieldTypeMenu.vault_column(field_type, abbrev)

        assert migration_src =~ "add(:#{expected_column}, :text)",
               "field_type #{field_type}: expected the migration to create #{expected_column}, " <>
                 "got:\n#{migration_src}"

        # The scalar/composite split is exactly {address} vs everything else in
        # THIS menu — an explicit anti-tautology check that the predicate isn't
        # vacuously true for every entry.
        if field_type == "address" do
          assert expected_column == "#{abbrev}_secret"
        else
          assert expected_column == "pii_#{abbrev}_secret"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "validate_resource!/2 fail-closed rules" do
    setup do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      {:ok, dir: dir}
    end

    defp rspec(dir, opts \\ []) do
      Post.build_resource_spec(
        app_dir: dir,
        scope: opts[:scope] || "Crm",
        resource: opts[:resource] || "Widget",
        abbrev: opts[:abbrev] || "wdg",
        description: Keyword.get(opts, :description, @description)
      )
    end

    test "green: a fresh resource validates against an empty registry", %{dir: dir} do
      assert Post.validate_resource!(rspec(dir), %{}) == :ok
    end

    test "red: a non-3-letter abbrev is rejected", %{dir: dir} do
      assert_raise ArgumentError, ~r/exactly 3 lowercase letters/, fn ->
        Post.validate_resource!(rspec(dir, abbrev: "wd"), %{})
      end
    end

    test "red: a bad resource alias is rejected", %{dir: dir} do
      assert_raise ArgumentError, ~r/valid Elixir module alias/, fn ->
        Post.validate_resource!(rspec(dir, resource: "widget"), %{})
      end
    end

    test "red: a non-existent target scope is rejected (gen.scope first)", %{dir: dir} do
      assert_raise ArgumentError, ~r/does not exist.*samen.gen.scope/s, fn ->
        Post.validate_resource!(rspec(dir, scope: "Nope"), %{})
      end
    end

    test "red: an abbrev owned by a DIFFERENT module is rejected (host-scoped permanence)",
         %{dir: dir} do
      # The registry map is the app's OWN host namespace. A different owner there is the
      # real permanence violation (ADR-006/ADR-025 D7/D8-P2-1: routed through
      # validate_host/4). The refusal names the HOST namespace, not a blanket "global
      # registry" (P2-2 message fix).
      registry = %{"wdg" => "Someone.Else.Owner"}

      err =
        assert_raise ArgumentError, ~r/permanent within a host and never recycled/, fn ->
          Post.validate_resource!(rspec(dir), registry)
        end

      # P2-2: the message attributes the owner to THIS host (widgetco), not "the global
      # registry" — the location is now correct.
      assert err.message =~ ~s(host "widgetco")
      assert err.message =~ "Someone.Else.Owner"
      refute err.message =~ "global registry"
    end

    test "green: an abbrev already owned by the SAME module is fine (idempotent)", %{dir: dir} do
      registry = %{"wdg" => "Widgetco.Crm.Widget"}
      assert Post.validate_resource!(rspec(dir), registry) == :ok
    end

    test "red: an already-existing resource file is refused", %{dir: dir} do
      r = rspec(dir)
      Post.write_resource!(r)
      assert_raise ArgumentError, ~r/already exists/, fn -> Post.validate_resource!(r, %{}) end
    end
  end

  # ---------------------------------------------------------------------------
  describe "reserve_abbrevs!/2 (append-only, idempotent, permanence)" do
    setup do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      path = Path.join(System.tmp_dir!(), "gen_post_reg_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(%{"$comment" => "test", "abbrevs" => %{"aaa" => "Pre.Existing"}}))
      on_exit(fn -> File.rm(path) end)
      {:ok, dir: dir, path: path}
    end

    test "reserves the resource abbrev into the app HOST namespace (ADR-023), preserving the global net + comment",
         %{
           dir: dir,
           path: path
         } do
      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      assert Post.reserve_abbrevs!(r, path) == :ok

      decoded = File.read!(path) |> Jason.decode!()
      # host-namespaced write (host = the app's otp_app, read from mix.exs).
      assert decoded["hosts"]["widgetco"]["wdg"] == "Widgetco.Crm.Widget"
      refute Map.has_key?(decoded["abbrevs"], "wdg")
      # legacy global net + comment untouched.
      assert decoded["abbrevs"]["aaa"] == "Pre.Existing"
      assert decoded["$comment"] == "test"
    end

    test "is idempotent — a second reservation is a no-op", %{dir: dir, path: path} do
      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      Post.reserve_abbrevs!(r, path)
      before = File.read!(path)
      Post.reserve_abbrevs!(r, path)
      assert File.read!(path) == before
    end

    test "refuses to hand a reserved abbrev to a different owner", %{dir: dir, path: path} do
      # aaa is already Pre.Existing.
      r =
        Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "aaa", description: @description)

      assert_raise ArgumentError, ~r/already owned by Pre.Existing/, fn ->
        Post.reserve_abbrevs!(r, path)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "write_resource!/1 emits the full file set + wires the domain" do
    test "emits the resource, migration, four G26 files, probe; wires into the scope" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      Post.write_resource!(r)

      # Resource module.
      res = File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))
      assert res =~ "defmodule Widgetco.Crm.Widget do"
      assert res =~ ~s(abbrev: "wdg")
      # Tier-0: admin-gated writes use forbid_unless(OrgScope) (not authorize_if — which
      # would short-circuit past the role gate). This is load-bearing (the D7a policy bug).
      assert res =~ "forbid_unless(Samen.Policy.OrgScope)"
      assert res =~ "forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})"
      # One scalar vault field so vault-routing is non-vacuous.
      assert res =~ "pii_attribute(:secret, :string,\n      vault: :pii_secret,"

      # Migration with catalog_sync.
      mig = Path.wildcard(Path.join(dir, "priv/repo/migrations/*_add_widget.exs"))
      assert length(mig) == 1
      migsrc = File.read!(hd(mig))
      assert migsrc =~ "create table(:wdg_widget"
      assert migsrc =~ "catalog_sync(@resources)"

      # The four mandated G26 files, as thin RedPath macro calls.
      pm = File.read!(Path.join(dir, "test/crm_widget_policy_matrix_test.exs"))
      assert pm =~ "use Samen.RedPath, repo: Widgetco.Repo"
      assert pm =~ "policy_matrix("

      rbac = File.read!(Path.join(dir, "test/crm_widget_rbac_red_path_test.exs"))
      assert rbac =~ "rbac_role_model()"
      assert rbac =~ "admin_gate_red_path("

      vault = File.read!(Path.join(dir, "test/crm_widget_vault_routing_test.exs"))
      assert vault =~ "vault_routing("

      cat = File.read!(Path.join(dir, "test/crm_widget_catalog_parity_red_path_test.exs"))
      assert cat =~ "catalog_parity_red_path("
      assert cat =~ ~s(table: "wdg_widget")

      # Per-resource anti-tautology probe.
      assert File.exists?(Path.join(dir, "priv/crm_widget_anti_tautology_probe.exs"))

      # Wired into the scope domain.
      scope = File.read!(Path.join(dir, "lib/widgetco/crm.ex"))
      assert scope =~ "resource(Widgetco.Crm.Widget)"
    end

    test "a second resource appends into the same populated scope block" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      Post.write_resource!(
        Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description)
      )

      Post.write_resource!(
        Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Gadget", abbrev: "gdg")
      )

      scope = File.read!(Path.join(dir, "lib/widgetco/crm.ex"))
      assert scope =~ "resource(Widgetco.Crm.Widget)"
      assert scope =~ "resource(Widgetco.Crm.Gadget)"
      # Both are inside the resources block (the closing `end` follows both).
      assert scope =~ ~r/resource\(Widgetco\.Crm\.Widget\)\n\s*resource\(Widgetco\.Crm\.Gadget\)/
    end
  end

  describe "write_resource!/1 with live?: true (--live) emits CRUD LiveViews + wires routes" do
    # A minimal router carrying the aliased browser scope the generated app ships, so
    # wire_live_routes!/1 has the exact anchor it injects after.
    defp fake_router!(dir) do
      File.mkdir_p!(Path.join(dir, "lib/widgetco_web"))

      File.write!(Path.join(dir, "lib/widgetco_web/router.ex"), """
      defmodule WidgetcoWeb.Router do
        use Phoenix.Router
        import Phoenix.LiveView.Router
        import Samen.Web.Router

        pipeline :browser do
          plug(:accepts, ["html"])
        end

        scope "/", WidgetcoWeb do
          pipe_through(:browser)

          get("/", PageController, :index)
          get("/healthz", PageController, :healthz)
          get("/readyz", PageController, :readyz)
        end
      end
      """)
    end

    test "emits index/show/form LiveViews + a mount-smoke test, and wires the four live/3 routes" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      fake_router!(dir)

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", live: true)
      assert r.live?
      Post.write_resource!(r)

      # The three CRUD LiveViews land under lib/<app>_web/<scope>/, on the Samen.UI kit.
      idx = File.read!(Path.join(dir, "lib/widgetco_web/crm/widget_index_live.ex"))
      assert idx =~ "defmodule WidgetcoWeb.Crm.WidgetIndexLive do"
      assert idx =~ "import Samen.UI"
      # Masking by construction: reads under a tenant-plane scope; the PII resolver
      # (the resource preparation) resolves the vault field — never hand-masked here.
      assert idx =~ "plane: :tenant"

      show = File.read!(Path.join(dir, "lib/widgetco_web/crm/widget_show_live.ex"))
      assert show =~ "defmodule WidgetcoWeb.Crm.WidgetShowLive do"
      # The 🔒 field is rendered straight from the already-resolved read record
      # (through the type-safe `render_secret/1` helper — ADR-036 H7/T15: the plane-
      # resolved value can be a non-Phoenix.HTML.Safe struct/Decimal for some menu
      # types, e.g. Money/Address/Percent, not just a Masked/binary/nil).
      assert show =~ "{render_secret(@record.secret)}"

      form = File.read!(Path.join(dir, "lib/widgetco_web/crm/widget_form_live.ex"))
      assert form =~ "defmodule WidgetcoWeb.Crm.WidgetFormLive do"
      assert form =~ "AshPhoenix.Form.for_create"
      assert form =~ "AshPhoenix.Form.for_update"

      # The emitted mount-smoke test.
      smoke = File.read!(Path.join(dir, "test/crm_widget_live_smoke_test.exs"))
      assert smoke =~ "defmodule Widgetco.Crm.WidgetLiveSmokeTest do"
      assert smoke =~ "use Widgetco.DataCase"

      # The four live/3 routes wired into the aliased browser scope, /new before /:id.
      router = File.read!(Path.join(dir, "lib/widgetco_web/router.ex"))
      assert router =~ ~s|live("/crm/widget", Crm.WidgetIndexLive, :index)|
      assert router =~ ~s|live("/crm/widget/new", Crm.WidgetFormLive, :new)|
      assert router =~ ~s|live("/crm/widget/:id/edit", Crm.WidgetFormLive, :edit)|
      assert router =~ ~s|live("/crm/widget/:id", Crm.WidgetShowLive, :show)|
      assert router =~ ~r/live\("\/crm\/widget\/new".*\n.*live\("\/crm\/widget\/:id\/edit".*\n.*live\("\/crm\/widget\/:id"/
    end

    test "default (no --live) emits NO LiveViews and leaves the router untouched" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      fake_router!(dir)
      before = File.read!(Path.join(dir, "lib/widgetco_web/router.ex"))

      Post.write_resource!(Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: @description))

      refute File.exists?(Path.join(dir, "lib/widgetco_web/crm/widget_index_live.ex"))
      refute File.exists?(Path.join(dir, "test/crm_widget_live_smoke_test.exs"))
      assert File.read!(Path.join(dir, "lib/widgetco_web/router.ex")) == before
    end

    test "live route wiring is idempotent — a re-run does not double-insert" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      fake_router!(dir)

      spec = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", live: true)
      Post.write_resource_live!(spec, Post.resource_bindings(spec))
      Post.write_resource_live!(spec, Post.resource_bindings(spec))

      router = File.read!(Path.join(dir, "lib/widgetco_web/router.ex"))
      matches = router |> String.split(~s|live("/crm/widget", Crm.WidgetIndexLive, :index)|) |> length()
      assert matches == 2, "expected exactly one index route, found #{matches - 1}"
    end
  end

  # ---------------------------------------------------------------------------
  describe "ADR-043 §8a (A3): the generated resource is described by construction" do
    # Every `description` the generated resource carries, keyed by what it describes — read from the AST of the
    # EMITTED source (not a string match), so a template that drops one is caught here.
    defp described(src) do
      {:ok, ast} = Code.string_to_quoted(src)

      {_, acc} =
        Macro.prewalk(ast, %{resource: nil, fields: %{}}, fn
          {:resource, _, [[do: {:description, _, [d]}]]} = n, acc when is_binary(d) ->
            {n, %{acc | resource: d}}

          {:attribute, _, [name, _type, [do: body]]} = n, acc ->
            {n, put_field(acc, name, block_description(body))}

          {:attribute, _, [name, _type, opts]} = n, acc when is_list(opts) ->
            {n, put_field(acc, name, opts[:description])}

          {:pii_attribute, _, [name, _type, opts]} = n, acc when is_list(opts) ->
            {n, put_field(acc, name, opts[:description])}

          n, acc ->
            {n, acc}
        end)

      acc
    end

    defp put_field(acc, name, description), do: %{acc | fields: Map.put(acc.fields, name, description)}

    defp block_description({:__block__, _, calls}), do: Enum.find_value(calls, &block_description/1)
    defp block_description({:description, _, [d]}) when is_binary(d), do: d
    defp block_description(_), do: nil

    test "RED: the resource, name, label, status and the vault field are each described, for EVERY field type" do
      for field_type <- Samen.Gen.FieldTypeMenu.menu() do
        dir = fake_app!()
        Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

        r =
          Post.build_resource_spec(
            app_dir: dir,
            scope: "Crm",
            resource: "Widget",
            abbrev: "wdg",
            description: @description,
            field_type: field_type
          )

        Post.validate_resource!(r, %{})
        Post.write_resource!(r)
        %{resource: resource, fields: fields} = described(File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex")))

        assert resource == @description, "#{field_type}: the resource description is the --description, verbatim"
        assert Map.keys(fields) |> Enum.sort() == [:label, :name, :secret, :status], "#{field_type}: fixed scaffold fields"

        for {name, description} <- fields do
          assert is_binary(description), "#{field_type}: field #{name} is emitted WITHOUT a description"

          assert CatalogMeaning.description_problems(description, [to_string(name)]) == [],
                 "#{field_type}: field #{name}: #{inspect(description)}"
        end

        refute inspect(fields) =~ "vt_", "a vault field's description describes the schema, never a value"

        # Only what is enforced: `status` is a one_of with a default; create accepts any of the three values and nothing
        # enforces a lifecycle, so the text claims neither "new entries start active" nor a "lifecycle".
        assert fields[:status] =~ "one of active, paused or archived; defaults to active"
        refute fields[:status] =~ ~r/lifecycle|new entries/i

        # The vault field's planes are the ones `Samen.Api.PiiResolution` implements (pii_resolution_planes_test.exs).
        assert fields[:secret] =~ "clear on the owning organization's tenant plane"
        assert fields[:secret] =~ "masked or omitted on other planes"
        refute fields[:secret] =~ "on every read"
      end
    end

    test "RED: validate_resource! refuses a missing description and each rule the verifier applies" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      spec = fn d -> Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: d) end

      for {bad, rule} <- [
            {nil, "is missing"},
            {"Widget", "fewer than 3 words"},
            {"TODO describe the widget soon", "placeholder"},
            {"The vault holds vt_abc for it", "vault-token sentinel"},
            {"The widget of widgets", "restates the name"},
            {String.duplicate("long words here ", 30), "longer than 300"}
          ] do
        assert_raise ArgumentError, ~r/--description .*#{Regex.escape(rule)}/, fn -> Post.validate_resource!(spec.(bad), %{}) end
      end

      assert Post.validate_resource!(spec.(@description), %{}) == :ok
    end

    test "the generator's rule IS the verifier's: description_problems/3 delegates to Samen.CatalogMeaning" do
      for d <- ["Widget", "TODO describe the widget soon", @description] do
        verifier = CatalogMeaning.description_problems(d, ["Widget", "widget", "wdg_widget"])
        assert Enum.all?(verifier, &(&1 in Post.description_problems(d, "Widget", "wdg_widget")))
      end
    end

    test "a description with quotes or interpolation text is emitted as ONE escaped literal" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      d = ~S|A "quoted" widget with #{not_interpolated} text for teams|

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: d)
      Post.validate_resource!(r, %{})
      Post.write_resource!(r)

      assert described(File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))).resource == d
    end
  end

  describe "the description literal" do
    test "RED: a valid description above 4096 codepoints (inspect's default printable_limit) is emitted whole" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      # 283 graphemes (the rules count graphemes) but 4183 codepoints: each filler word is one letter plus 30 combining marks.
      filler = String.duplicate(" a" <> String.duplicate("\u0301", 30), 130)
      d = "A team keeps this label" <> filler
      assert String.length(d) <= 300 and length(String.to_charlist(d)) > 4096
      assert Post.description_problems(d, "Widget", "wdg_widget") == []

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: d)
      Post.validate_resource!(r, %{})
      Post.write_resource!(r)

      src = File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))
      assert described(src).resource == d, "the emitted literal is the description, not a truncated `\"...\" <> ...` expression"
    end
  end

  describe "the renderer is single-pass" do
    test "RED: a description holding `<%= table %>` (a key bound AFTER description_literal) is emitted literally and round-trips" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      d = "A widget the team keeps; writes <%= table %> and <%= abbrev %> and <%= module %> as text only"

      r = Post.build_resource_spec(app_dir: dir, scope: "Crm", resource: "Widget", abbrev: "wdg", description: d)
      assert Post.description_problems(d, "Widget", "wdg_widget") == [], "template syntax is not refused: the renderer never re-scans a value"
      Post.validate_resource!(r, %{})
      Post.write_resource!(r)

      src = File.read!(Path.join(dir, "lib/widgetco/crm/widget.ex"))
      assert described(src).resource == d
      assert src =~ "<%= table %>"
    end

    test "App.render/2 never expands a substituted value, leaves an unbound key as written, and the first duplicate binding wins" do
      assert App.render("<%= a %>|<%= b %>", a: "<%= b %>", b: "B") == "<%= b %>|B"
      assert App.render("<%= zz %> <%= a %>", %{"a" => 1}) == "<%= zz %> 1"
      assert App.render("<%= a %>", [{:a, "first"}, {:a, "second"}]) == "first"
    end
  end

  describe "mix samen.gen.resource --description" do
    test "RED: refuses a missing --description, with a hint showing the flag, before writing anything" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))
      before = Path.wildcard(Path.join(dir, "**/*"))

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Samen.Gen.Resource.run(~w(--scope Crm --resource Widget --abbrev wdg --app-dir #{dir} --no-reserve-abbrevs))
        end

      assert error.message =~ "missing required --description"
      assert error.message =~ ~s(--description ")
      assert Path.wildcard(Path.join(dir, "**/*")) == before
    end

    test "RED: refuses a description the verifier would flag, naming the rule" do
      dir = fake_app!()
      Post.write_scope!(Post.build_scope_spec(app_dir: dir, scope: "Crm"))

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Samen.Gen.Resource.run(
            ~w(--scope Crm --resource Widget --abbrev wdg --app-dir #{dir} --no-reserve-abbrevs) ++ ["--description", "Widget"]
          )
        end

      assert error.message =~ "fewer than 3 words"
    end
  end
end
