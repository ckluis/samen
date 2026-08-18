defmodule Samen.Gen.ScopeAuthnErgonomicsTest do
  @moduledoc """
  W4-H2 defense-in-depth (cleanup Batch H3): `mix samen.gen.scope` closes the DX gap that made
  the pawchart W4 BLOCKER-1 possible. A business-domain scope's tenant mount must carry the
  `@current_org_labels`/`:authn` seam or be CAUGHT. gen.scope now (a) prints an AUTHN-WIRED
  router snippet as GUIDANCE, and (b) emits a FAILING-UNTIL-WIRED coverage guard test.

  The SECURITY hole itself is already closed (Batch-1 fail-closed resolution) and CAUGHT
  (Batch-7 enumerating guards) — this pins the ERGONOMICS: the generator's OUTPUT (the emitted
  guard template + the printed guidance snippet) so a regression that emits a BARE unlabeled
  mount / drops the seam flips a named test here (see scripts/sabotages/192-*).

  The end-to-end "a freshly generated app gets the guard, it passes green, and it FLIPS when a
  bare unlabeled tenant mount is present" claim is covered by `priv/gen_post_probe.exs`.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.Post
  alias Samen.Gen.PostTemplates

  # A directly-constructed spec — hermetic (no app dir, no disk) for the pure-output pins.
  defp spec, do: %Post.ScopeSpec{
    app_module: "Widgetco",
    otp_app: :widgetco,
    app_dir: "/nonexistent",
    scope: "Crm",
    scope_module: "Widgetco.Crm"
  }

  describe "the emitted authn-coverage guard template (the failing-until-wired half)" do
    test "asserts every tenant mount carries the :authn seam, enumerated off the REAL router" do
      guard = PostTemplates.tenant_authn_coverage_test()

      assert guard =~ "TenantAuthnCoverageTest"
      # The load-bearing assertion: the emitted guard checks the :authn seam on every mount.
      assert guard =~ "Mount.label(mount, :authn, nil) == {:app_env, :<%= otp_app %>, :auth_required?}"
      # It enumerates the REAL compiled router (routes extracted, not hand-built) …
      assert guard =~ "<%= module %>Web.Router.__routes__()"
      # … and filters to PII-bearing tenant scope kinds (identity/pre-actor mounts excluded).
      assert guard =~ "mount.scope_kind in @tenant_kinds"
      # It carries a refutability twin so the armed denial is non-vacuous.
      assert guard =~ "REFUTABILITY"
    end
  end

  describe "the printed router guidance (the guided half)" do
    test "the mount snippet carries the @current_org_labels seam — never a bare mount" do
      guidance = Post.scope_router_guidance(spec())

      # The exact mount snippet the author copies MUST carry the authn seam — a BARE mount
      # (`samen_module_routes(:crm, Widgetco.Crm, repo: Widgetco.Repo)`, no labels) is the W4
      # leak, so the whole labeled call must be present verbatim (prose mentions do not count).
      assert guidance =~
               "samen_module_routes(:crm, Widgetco.Crm, repo: Widgetco.Repo, labels: @current_org_labels)"

      # It must NAME the leak it prevents so the author understands WHY the label is load-bearing.
      assert guidance =~ "leak"
      assert guidance =~ "tenant_authn_coverage_test.exs"
    end
  end

  describe "write_scope! emits the guard (idempotent — authored once per app)" do
    test "writes test/tenant_authn_coverage_test.exs on first scope and does not overwrite on later runs" do
      s = %{spec() | app_dir: fake_app!()}

      Post.write_scope!(s)

      guard = Path.join(s.app_dir, "test/tenant_authn_coverage_test.exs")
      assert File.exists?(guard)
      body = File.read!(guard)
      # The rendered guard is the concrete app-namespaced module wired to the app's router.
      assert body =~ "defmodule WidgetcoWeb.TenantAuthnCoverageTest"
      assert body =~ "WidgetcoWeb.Router.__routes__()"
      assert body =~ "{:app_env, :widgetco, :auth_required?}"

      # Idempotent: a SECOND scope leaves the existing guard byte-exact (authored once).
      before = File.read!(guard)
      s2 = %{s | scope: "Support", scope_module: "Widgetco.Support"}
      Post.write_scope!(s2)
      assert File.read!(guard) == before
    end
  end

  # A minimal fake generated-app tree: mix.exs (identity) + config (both :ash_domains lists).
  defp fake_app! do
    dir = Path.join(System.tmp_dir!(), "gen_scope_authn_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "config"))
    File.mkdir_p!(Path.join(dir, "lib/widgetco"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Widgetco.MixProject do
      use Mix.Project
      def project, do: [app: :widgetco]
      def application, do: [mod: {Widgetco.Application, []}]
    end
    """)

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config

    config :widgetco, ash_domains: [Widgetco.Billing]
    config :samen_core, :ash_domains, [Widgetco.Billing]
    """)

    dir
  end
end
