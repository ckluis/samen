defmodule Samen.FleetPublicStatusTest do
  @moduledoc """
  T166 (G11, ADR-050) — the PUBLIC-PLANE projection `Samen.Fleet.PublicStatus`.

  The feature's whole claim is a NARROWING: the operator cockpit row
  (`Samen.Fleet.Registry.read_rows/2`, which carries `app_id`, `display_name`,
  `base_url`, `transport`, `received_at` and the raw producer `payload`) is
  projected down to `{slug, status}` where `status` is drawn from a CLOSED public
  vocabulary that is deliberately SMALLER than the internal one. So the tests here
  are the three proofs of a masking surface:

    * GREEN — the right plane renders the published apps with the right public enum;
    * RED — the wrong plane renders `••••` and NEVER plaintext, and no internal
      identifier, timestamp, payload value or internal enum name survives the
      projection (the `vt_`-shaped smuggled value is the named red);
    * the durable twins are sabotage patches 360/361/362.

  Probing is NOT re-implemented here: staleness/dead-man semantics come from
  `build_row/3` (ADR-044 §4.6), which this projection consumes verbatim.
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.{AdminActor, PublicStatus, Registry}
  alias SamenCore.TestRepo

  @ns SamenCore.Support.FleetFixture
  @admin AdminActor.new("status-admin")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp seed_app(slug, opts) do
    attrs =
      %{slug: slug, display_name: Keyword.get(opts, :display_name, "Display #{slug}")}
      |> maybe_put(:publish_status, Keyword.get(opts, :publish_status))
      |> maybe_put(:stale_after_s, Keyword.get(opts, :stale_after_s))
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

  defp entries!(opts \\ []) do
    {:ok, %{entries: entries}} = PublicStatus.read(@ns, opts)
    entries
  end

  # ---------------------------------------------------------------------------
  # GREEN — the right plane
  # ---------------------------------------------------------------------------

  describe "GREEN: the published plane" do
    test "an opted-in app with a fresh report is :operational, keyed by slug" do
      seed_app("alpha-api", publish_status: true, report: payload())

      assert [%PublicStatus.Entry{slug: "alpha-api", status: :operational}] = entries!()
    end

    test "overall is the WORST published status, and :unknown when nothing is published" do
      assert {:ok, %{overall: :unknown, entries: []}} = PublicStatus.read(@ns)

      seed_app("alpha-api", publish_status: true, report: payload())
      assert {:ok, %{overall: :operational}} = PublicStatus.read(@ns)

      # No report at all -> internal :unreachable -> public :down, which outranks.
      seed_app("beta-api", publish_status: true)
      assert {:ok, %{overall: :down}} = PublicStatus.read(@ns)
    end

    test "entries are sorted by slug (a stable page, not insertion order)" do
      seed_app("zeta", publish_status: true, report: payload())
      seed_app("alpha", publish_status: true, report: payload())

      assert ["alpha", "zeta"] == entries!() |> Enum.map(& &1.slug)
    end

    test "the dead-man staleness ADR-044 already ships is CONSUMED, not re-derived: overdue -> :degraded" do
      # stale_after_s: 0 means the report received a moment ago is already overdue
      # by build_row/3's own predicate — no second staleness notion here.
      app = seed_app("gamma-api", publish_status: true, stale_after_s: 0, report: payload())
      # A second report so received_at is strictly in the past by >0s.
      Process.sleep(1100)
      {:ok, _} = Registry.record_report(@ns, app.id, payload(), :pull)
      Process.sleep(1100)

      assert [%PublicStatus.Entry{slug: "gamma-api", status: :degraded}] = entries!()
    end
  end

  # ---------------------------------------------------------------------------
  # OPT-IN is fail-closed
  # ---------------------------------------------------------------------------

  describe "opt-in publish (fail-closed)" do
    test "registering an app does NOT publish it — the default is unpublished" do
      app = seed_app("private-api", report: payload())

      assert entries!() == []
      refute app.publish_status
    end

    test "a deregistered app disappears from the public plane even while opted in" do
      app = seed_app("retiring-api", publish_status: true, report: payload())
      assert [%{slug: "retiring-api"}] = entries!()

      {:ok, _} = Registry.deregister_app(@ns, app.id, @admin)
      assert entries!() == []
    end

    test "publish is OPERATOR-initiated: the app's own heartbeat actor cannot flip it" do
      app = seed_app("self-promoting-api", report: payload())

      assert {:error, _} =
               Registry.set_publish_status(
                 @ns,
                 app.id,
                 true,
                 Samen.Fleet.HeartbeatActor.new(app.id)
               )

      assert entries!() == []

      # Positive control: the SAME call as the fleet admin does flip it.
      assert {:ok, _} = Registry.set_publish_status(@ns, app.id, true, @admin)
      assert [%{slug: "self-promoting-api"}] = entries!()

      # And it is reversible — unpublishing takes the app back off the page.
      assert {:ok, _} = Registry.set_publish_status(@ns, app.id, false, @admin)
      assert entries!() == []
    end
  end

  # ---------------------------------------------------------------------------
  # RED — the wrong plane renders ••••, never plaintext, never a vt_ token
  # ---------------------------------------------------------------------------

  describe "RED: nothing but slug + bounded enum crosses the plane" do
    test "RED: a vt_-shaped value smuggled into the slug renders •••• — never the token" do
      seed_app("vt_a1b2c3d4e5f6a7b8", publish_status: true, report: payload())

      assert [%PublicStatus.Entry{slug: slug, status: :operational}] = entries!()
      assert slug == "••••"
      refute slug =~ "vt_"
      refute slug =~ "a1b2c3d4"
    end

    test "RED: any slug outside the bounded operator shape renders ••••" do
      for bad <- ["Acme Corp GmbH", "ops@acme.example", "ACME", "vt_zzzz", String.duplicate("a", 80)] do
        {:ok, %{app: app}} =
          Registry.register_app(@ns, %{slug: bad, display_name: "d", publish_status: true}, @admin)

        {:ok, _} = Registry.record_report(@ns, app.id, payload(), :pull)

        assert [%PublicStatus.Entry{slug: "••••"}] = entries!(),
               "slug #{inspect(bad)} is not the bounded operator shape and must be masked"

        {:ok, _} = Registry.deregister_app(@ns, app.id, @admin)
      end
    end

    test "POSITIVE CONTROL for the mask: the bounded shape is NOT masked" do
      seed_app("acme-api-2", publish_status: true, report: payload())
      assert [%PublicStatus.Entry{slug: "acme-api-2"}] = entries!()
    end

    test "RED: no internal identifier, timestamp, URL or payload value survives the projection" do
      leaks = %{
        "tenant_display_name" => "Acme Corporation GmbH",
        "smuggled_token" => "vt_deadbeefdeadbeef",
        "internal_note" => "org 11111111-1111-4111-8111-111111111111"
      }

      app =
        seed_app("leaky-api",
          display_name: "Acme Corporation GmbH",
          base_url: "https://acme-internal.example/health",
          publish_status: true,
          report: payload(leaks)
        )

      rendered = entries!() |> inspect(limit: :infinity, printable_limit: :infinity)

      for forbidden <- [
            app.id,
            "Acme Corporation GmbH",
            "acme-internal.example",
            "vt_deadbeefdeadbeef",
            "tenant_display_name",
            "11111111-1111-4111-8111-111111111111",
            "pull"
          ] do
        refute rendered =~ forbidden,
               "#{inspect(forbidden)} reached the public plane: #{rendered}"
      end

      # POSITIVE CONTROL: every one of those values IS present on the operator
      # cockpit plane the projection reads from — so the refutes above are
      # refuting something that genuinely exists upstream, not a typo.
      {:ok, rows} = Registry.read_rows(@ns, actor: @admin)
      cockpit = inspect(rows, limit: :infinity, printable_limit: :infinity)

      for present <- [app.id, "Acme Corporation GmbH", "vt_deadbeefdeadbeef", "tenant_display_name"] do
        assert cockpit =~ present,
               "#{inspect(present)} is NOT on the cockpit plane — the red above proves nothing"
      end
    end

    test "RED: the internal status vocabulary never appears on the public plane" do
      seed_app("a-api", publish_status: true, report: payload())
      seed_app("b-api", publish_status: true)

      statuses = entries!() |> Enum.map(& &1.status)

      for internal <- [:active, :stale, :unreachable, :revoked, :deregistered] do
        refute internal in statuses,
               "internal enum #{inspect(internal)} crossed to the public plane"
      end

      assert Enum.all?(statuses, &(&1 in PublicStatus.public_statuses()))
    end

    test "the Entry struct is a CLOSED two-field shape — widening it is a visible act" do
      assert [:slug, :status] ==
               %PublicStatus.Entry{slug: "x", status: :operational}
               |> Map.from_struct()
               |> Map.keys()
               |> Enum.sort()
    end
  end

  # ---------------------------------------------------------------------------
  # Fail closed
  # ---------------------------------------------------------------------------

  describe "fail closed" do
    test "an unreadable namespace is {:error, :unavailable} — never a fabricated all-clear" do
      assert {:error, :unavailable} = PublicStatus.read(SamenCore.Support.NoSuchFleetNamespace)
    end
  end
end
