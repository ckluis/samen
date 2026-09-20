defmodule Samen.Web.FleetPublicStatusTest do
  @moduledoc """
  T166 / ADR-050 — HTTP-layer proof of the PUBLIC status page
  (`Samen.Web.Fleet.PublicStatus`), at the level the sabotage patches flip
  against: real status codes, real response headers, real rendered bytes.

  The surface's four claims, each with a named test:

    1. it is UNAUTHENTICATED and rate-limited (429 past the window, and the 429
       carries no body to differentiate a known from an unknown fleet);
    2. it renders ONLY opted-in apps, and opt-in defaults to off;
    3. nothing but slug + bounded public enum reaches the bytes — no `app_id`, no
       `display_name`, no `base_url`, no `received_at`, no producer payload value,
       no `vt_*` token, no internal status word — and a slug outside the bounded
       operator shape renders `••••`;
    4. it fails CLOSED: an unreadable substrate is a 503 saying so, never an empty
       page that reads as all-clear, and it never sets a session cookie.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test

  alias Samen.Fleet.{AdminActor, Registry}
  alias Samen.Web.Fleet.PublicStatus
  alias Samen.Web.RateLimit

  @ns Samen.WebTest.Fleet
  @admin AdminActor.new("status-admin")
  @opts [namespace: @ns]

  setup do
    RateLimit.reset()

    on_exit(fn ->
      Application.delete_env(:samen_web, RateLimit)
      RateLimit.reset()
    end)

    :ok
  end

  defp seed_app(slug, opts) do
    attrs =
      %{slug: slug, display_name: Keyword.get(opts, :display_name, "Display #{slug}")}
      |> maybe_put(:publish_status, Keyword.get(opts, :publish_status))
      |> maybe_put(:base_url, Keyword.get(opts, :base_url))

    {:ok, %{app: app}} = Registry.register_app(@ns, attrs, @admin)

    if payload = Keyword.get(opts, :report) do
      {:ok, _} = Registry.record_report(@ns, app.id, payload, :pull)
    end

    app
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp payload(overrides \\ %{}) do
    Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Samen.Fleet.Report.to_wire()
    |> Map.merge(overrides)
  end

  defp get_status(path \\ "/status", opts \\ @opts) do
    conn(:get, path) |> PublicStatus.index(opts)
  end

  defp limit_to(n) do
    Application.put_env(:samen_web, RateLimit, limits: %{public_status_ip: {n, 60_000}})
  end

  # ---------------------------------------------------------------------------
  # 1. Unauthenticated + rate-limited
  # ---------------------------------------------------------------------------

  describe "public + rate-limited" do
    test "GREEN (control): an unauthenticated GET with no session/cookie/header -> 200 HTML" do
      seed_app("alpha-api", publish_status: true, report: payload())

      resp = get_status()

      assert resp.status == 200
      assert {"content-type", "text/html; charset=utf-8"} in resp.resp_headers
      assert resp.resp_body =~ "alpha-api"
    end

    test "RED: over the per-IP window -> 429 with an EMPTY body (no fleet existence oracle)" do
      seed_app("alpha-api", publish_status: true, report: payload())
      limit_to(2)

      assert get_status().status == 200
      assert get_status().status == 200

      over = get_status()
      assert over.status == 429
      assert over.resp_body == ""
      refute over.resp_body =~ "alpha-api"
    end

    test "POSITIVE CONTROL for the limiter: a raised limit lets the same third request through" do
      seed_app("alpha-api", publish_status: true, report: payload())
      limit_to(2)

      assert get_status().status == 200
      assert get_status().status == 200
      assert get_status().status == 429

      RateLimit.reset()
      limit_to(10)
      assert get_status().status == 200
      assert get_status().status == 200
      assert get_status().status == 200
    end

    test "the limiter is keyed per REMOTE IP, and the key carries no tenant value" do
      seed_app("alpha-api", publish_status: true, report: payload())
      limit_to(1)

      a = conn(:get, "/status") |> Map.put(:remote_ip, {203, 0, 113, 7}) |> PublicStatus.index(@opts)
      assert a.status == 200

      # Same IP again -> over the window.
      a2 = conn(:get, "/status") |> Map.put(:remote_ip, {203, 0, 113, 7}) |> PublicStatus.index(@opts)
      assert a2.status == 429

      # A DIFFERENT IP still gets served — so the bucket is per-IP, not global.
      b = conn(:get, "/status") |> Map.put(:remote_ip, {198, 51, 100, 9}) |> PublicStatus.index(@opts)
      assert b.status == 200
    end

    test "no session cookie is ever set on the public surface" do
      seed_app("alpha-api", publish_status: true, report: payload())

      resp = get_status()

      refute Enum.any?(resp.resp_headers, fn {k, _v} -> k == "set-cookie" end)
      assert resp.resp_cookies == %{}
    end

    test "request params can never widen the plane" do
      seed_app("alpha-api", publish_status: true, report: payload())
      private = seed_app("private-api", report: payload())

      resp = get_status("/status?org_id=#{private.org_id}&app_id=#{private.id}&all=true")

      assert resp.status == 200
      refute resp.resp_body =~ "private-api"
      refute resp.resp_body =~ private.id
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Opt-in
  # ---------------------------------------------------------------------------

  describe "opt-in publish" do
    test "RED: an app that never opted in is absent from the rendered page" do
      seed_app("private-api", report: payload())

      resp = get_status()

      assert resp.status == 200
      refute resp.resp_body =~ "private-api"
    end

    test "POSITIVE CONTROL: the SAME app, opted in, does appear" do
      app = seed_app("private-api", report: payload())
      refute get_status().resp_body =~ "private-api"

      {:ok, _} = Registry.set_publish_status(@ns, app.id, true, @admin)

      assert get_status().resp_body =~ "private-api"
    end

    test "an empty page says so — it never renders a fabricated all-clear" do
      resp = get_status()

      assert resp.status == 200
      assert resp.resp_body =~ "No components are published"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Nothing but slug + bounded enum reaches the bytes
  # ---------------------------------------------------------------------------

  describe "RED: the rendered bytes" do
    test "RED: no app_id, display_name, base_url, transport, timestamp or payload value is rendered" do
      leaks = %{
        "tenant_display_name" => "Acme Corporation GmbH",
        "smuggled_token" => "vt_deadbeefdeadbeef"
      }

      app =
        seed_app("leaky-api",
          display_name: "Acme Corporation GmbH",
          base_url: "https://acme-internal.example/health",
          publish_status: true,
          report: payload(leaks)
        )

      body = get_status().resp_body

      for forbidden <- [
            app.id,
            "Acme Corporation GmbH",
            "acme-internal.example",
            "vt_deadbeefdeadbeef",
            "tenant_display_name",
            "schema_version"
          ] do
        refute body =~ forbidden, "#{inspect(forbidden)} reached the public bytes"
      end

      # POSITIVE CONTROL: every one of those IS upstream of this page — on the
      # cockpit row it projects from, or on the app row that row is built from —
      # so the refutes above refute something real.
      {:ok, rows} = Registry.read_rows(@ns, actor: @admin)
      cockpit = inspect(rows, limit: :infinity, printable_limit: :infinity)

      for present <- [app.id, "Acme Corporation GmbH", "vt_deadbeefdeadbeef", "tenant_display_name"] do
        assert cockpit =~ present, "#{inspect(present)} is not upstream — the red proves nothing"
      end

      {:ok, app_row} = Registry.get_app(@ns, app.id, @admin)
      assert app_row.base_url =~ "acme-internal.example"

      # And the slug that IS allowed through is there, so the page is not simply blank.
      assert body =~ "leaky-api"
    end

    test "RED: a vt_-shaped slug renders •••• — never the token" do
      seed_app("vt_a1b2c3d4e5f6a7b8", publish_status: true, report: payload())

      body = get_status().resp_body

      assert body =~ "••••"
      refute body =~ "vt_"
      refute body =~ "a1b2c3d4"
    end

    test "RED: the internal status vocabulary is never rendered" do
      seed_app("a-api", publish_status: true, report: payload())
      seed_app("b-api", publish_status: true)

      body = get_status().resp_body

      for internal <- ["unreachable", "deregistered", "revoked", "stale"] do
        refute body =~ internal, "internal status word #{inspect(internal)} was rendered"
      end

      assert body =~ "Operational"
      assert body =~ "Down"
    end

    test "the page escapes its operator-authored title (no markup injection through a label)" do
      seed_app("alpha-api", publish_status: true, report: payload())

      resp =
        conn(:get, "/status")
        |> PublicStatus.index(namespace: @ns, labels: %{title: ~s(<script>x</script>)})

      assert resp.resp_body =~ "&lt;script&gt;"
      refute resp.resp_body =~ "<script>x</script>"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Fail closed
  # ---------------------------------------------------------------------------

  describe "fail closed" do
    test "RED: an unreadable substrate -> 503 that SAYS it is unavailable, never an empty all-clear" do
      resp = get_status("/status", namespace: Samen.WebTest.NoSuchFleetNamespace)

      assert resp.status == 503
      assert resp.resp_body =~ "unavailable"
      refute resp.resp_body =~ "Operational"
      refute resp.resp_body =~ "NoSuchFleetNamespace"
    end

    test "RED: a mount with NO namespace -> 503, never a 200" do
      resp = get_status("/status", [])

      assert resp.status == 503
      refute resp.resp_body =~ "Operational"
    end
  end

  # ---------------------------------------------------------------------------
  # Route posture (enumerated, not asserted in prose)
  # ---------------------------------------------------------------------------

  describe "the mount" do
    test "samen_fleet_status_route/1 mounts exactly ONE public GET, through no auth pipeline" do
      routes = Samen.WebTest.PublicStatusRouter.__routes__()

      status_routes = Enum.filter(routes, &(&1.plug == Samen.Web.FleetStatusController))

      assert [route] = status_routes
      assert route.verb == :get
      assert route.path == "/status"
      assert route.plug_opts == :index

      # No LiveView on_mount hook and no authority gate anywhere in the metadata —
      # a public page that acquired one would stop being public silently.
      refute Map.has_key?(route.metadata, :on_mount)
      refute Map.has_key?(route.metadata, :samen_authority)
    end

    test "dispatched END-TO-END through the compiled router: no auth pipeline, and the mount's namespace arrives" do
      seed_app("routed-api", publish_status: true, report: payload())

      resp = conn(:get, "/status") |> Samen.WebTest.PublicStatusRouter.call([])

      # 200 with the published slug proves BOTH halves at once: nothing in the
      # mounted pipeline refused an identity-free request (it is genuinely public),
      # and the macro's `private: %{samen_fleet_status: ...}` reached the logic
      # module (otherwise this would be the 503 fail-closed page).
      assert resp.status == 200
      assert resp.resp_body =~ "routed-api"
      refute resp.resp_body =~ "unavailable"
    end

    test "the mount adds NO route under /fleet — the fleet_wire route surface is untouched" do
      paths = Samen.WebTest.PublicStatusRouter.__routes__() |> Enum.map(& &1.path)

      refute Enum.any?(paths, &String.starts_with?(&1, "/fleet"))
    end
  end
end
