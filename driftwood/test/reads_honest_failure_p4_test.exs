defmodule Driftwood.ReadsHonestFailureP4Test do
  @moduledoc """
  WP6 phase 4 — "a failed read never renders as empty, a zero or `driver not found`", and "a failed
  write tells the user", for the DRIFTWOOD vertical: the broker console (`/broker`: dashboard, loads,
  drivers, settlements), the operator impersonation console (roster, load board, reveal windows,
  reveal, request-reveal, open-session), the landing controller and the reveal helper.

  The framework's fault seam (`inject_read_faults/1`) is compiled out of a vertical build, so every
  failure here is REAL: Postgres DDL is transactional, so a `RENAME COLUMN` / a `CHECK (false) NOT
  VALID` constraint inside the sandbox transaction makes the very query or insert the screen runs
  fail, and rolls back with the test. Each failure is paired with a POSITIVE CONTROL (the same screen
  over a genuinely empty or healthy result still renders the real empty state / the real data), and
  with the recovery (the same call succeeds once the table is healthy again).

  The operator plane stays masked: an error state carries no name, no CDL and no `vt_` token.
  """
  use Driftwood.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive
  alias DriftwoodWeb.OperatorImpersonationLive, as: OpLive
  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.Reveal.Grants

  @org "c1230000-0000-4000-8000-0000000000f4"

  # -- harness -----------------------------------------------------------------------------------

  defp ddl!(sql), do: Ecto.Adapters.SQL.query!(Driftwood.Repo, sql, [])

  defp break_select!(table, column), do: ddl!("ALTER TABLE #{table} RENAME COLUMN #{column} TO #{column}_renamed")

  # A table whose every INSERT / UPDATE now fails: the write the screen runs fails, its reads still work.
  defp break_writes!(table), do: ddl!("ALTER TABLE #{table} ADD CONSTRAINT zz_p4_broken CHECK (false) NOT VALID")

  defp quiet(fun), do: fun |> with_log() |> elem(0)

  defp html(mod, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> mod.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp broker_socket(panel, extra \\ []) do
    flash_socket()
    |> Phoenix.Component.assign(
      [org_id: @org, panel: panel, samen_mount: nil, load_filter: %{status: nil, q: ""}] ++ extra
    )
  end

  defp flash_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  defp broker_load(panel, extra \\ []), do: BrokerLive.load_panel(broker_socket(panel, extra), panel, @org)

  defp broker_html(socket), do: html(BrokerLive, socket.assigns)

  defp broker_event(socket, name, params \\ %{}) do
    {:noreply, socket} = BrokerLive.handle_event(name, params, socket)
    socket
  end

  defp assert_error_state(rendered) do
    assert rendered =~ "error-state"
    assert rendered =~ ~s(role="alert")
    assert rendered =~ "Nothing was lost"
    refute rendered =~ "vt_"
  end

  defp seeded_load(name \\ "BRL-P4 dry van") do
    {:ok, load} = BrokerLive.create_load(@org, %{"name" => name, "lane" => "TX->CA", "rate" => "3200.00", "status" => "open"})
    load
  end

  defp seeded_driver(org \\ @org) do
    scope = BrokerLive.broker_scope(org)

    {:ok, driver} =
      Driftwood.Freight.Driver
      |> AshPhoenix.Form.for_create(:create, scope: scope)
      |> AshPhoenix.Form.submit(
        params: %{
          "org_id" => org,
          "full_name" => %{"first" => "Pat", "last" => "Haulwell"},
          "cdl_number" => "CDL-P4-0001",
          "cdl_state" => "TX",
          "cdl_expiry" => Date.to_iso8601(Date.add(Date.utc_today(), 365)),
          "medical_card_expiry" => Date.to_iso8601(Date.add(Date.utc_today(), 180)),
          "eld_provider" => "samsara",
          "status" => "available"
        }
      )

    driver
  end

  # ===========================================================================
  # Broker console: each panel reads through its tagged result and fails alone
  # ===========================================================================

  describe "broker loads panel" do
    test "a failed load board is the error state with a retry, not 'No loads yet' and no create CTA" do
      seeded_load()
      break_select!("fop_opportunity", "fop_status")

      socket = quiet(fn -> broker_load("loads") end)
      rendered = broker_html(socket)

      assert socket.assigns.loads_error == :unavailable
      assert_error_state(rendered)
      assert rendered =~ "retry_panel"
      refute rendered =~ "No loads yet"
      refute rendered =~ "Create your first load"
      refute rendered =~ "No loads match this filter"
      refute rendered =~ ~s(id="load-count")
    end

    test "the filter does not turn a failed read into 'No loads match this filter'" do
      break_select!("fop_opportunity", "fop_status")

      socket = quiet(fn -> broker_load("loads", load_filter: %{status: "open", q: "zzz"}) end)
      rendered = broker_html(socket)

      assert_error_state(rendered)
      refute rendered =~ "No loads match this filter"
    end

    test "retry recovers once the table is healthy again" do
      seeded_load()
      ddl!("ALTER TABLE fop_opportunity RENAME COLUMN fop_status TO fop_status_renamed")
      socket = quiet(fn -> broker_load("loads") end)
      assert socket.assigns.loads_error == :unavailable

      ddl!("ALTER TABLE fop_opportunity RENAME COLUMN fop_status_renamed TO fop_status")
      socket = broker_event(socket, "retry_panel")
      rendered = broker_html(socket)

      assert socket.assigns.loads_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "BRL-P4 dry van"
    end

    test "POSITIVE CONTROL: a genuinely empty board still renders the real empty state and its CTA" do
      socket = broker_load("loads")
      rendered = broker_html(socket)

      assert socket.assigns.loads_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "No loads yet"
      assert rendered =~ "Create your first load"
    end
  end

  describe "broker roster and settlements panels" do
    test "a failed roster is the error state, not an empty roster; the other panels are unaffected" do
      seeded_driver()
      break_select!("drv_driver", "drv_status")

      socket = quiet(fn -> broker_load("roster") end)
      rendered = broker_html(socket)

      assert socket.assigns.drivers_error == :unavailable
      assert_error_state(rendered)
      refute rendered =~ "driver-row"
      refute rendered =~ ~s(<span class="n">)

      # fails ALONE: the loads panel (a different table) still renders.
      seeded_load()
      loads = broker_html(broker_load("loads"))
      refute loads =~ "error-state"
      assert loads =~ "BRL-P4 dry van"
    end

    test "POSITIVE CONTROL: a seeded roster renders its rows with no error state" do
      driver = seeded_driver()
      socket = broker_load("roster")
      rendered = broker_html(socket)

      assert socket.assigns.drivers_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "driver-#{driver.id}"
    end

    test "a failed settlements read is the error state, not a zero-row table" do
      break_select!("stl_settlement", "stl_status")

      socket = quiet(fn -> broker_load("settlements") end)
      rendered = broker_html(socket)

      assert socket.assigns.settlements_error == :unavailable
      assert_error_state(rendered)
      refute rendered =~ "settlement-table"
      refute rendered =~ "settlement-row"
    end

    test "POSITIVE CONTROL: no settlements is an honest empty table" do
      socket = broker_load("settlements")
      rendered = broker_html(socket)

      assert socket.assigns.settlements_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "settlement-table"
    end
  end

  describe "broker dashboard rollup" do
    test "a failed rollup read is four 'couldn't load' tiles and an error state, never 0 loads / $0.00 / 'No settlements rolled up yet'" do
      break_select!("dbs_broker_summary", "dbs_gross_cents")

      socket = quiet(fn -> broker_load("dashboard") end)
      rendered = broker_html(socket)

      assert socket.assigns.summary_error == :unavailable
      assert_error_state(rendered)
      assert rendered =~ "metric-error"
      refute rendered =~ "No settlements rolled up yet"
      refute rendered =~ "summary-row"
    end

    test "POSITIVE CONTROL: an org with no rollup rows renders the honest empty dashboard" do
      socket = broker_load("dashboard")
      rendered = broker_html(socket)

      assert socket.assigns.summary_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "No settlements rolled up yet"
    end

    test "a malformed ?org= id is no rollup, with no failure logged" do
      log =
        capture_log(fn ->
          socket = BrokerLive.load_panel(broker_socket("dashboard", org_id: "not-a-uuid"), "dashboard", "not-a-uuid")
          assert socket.assigns.summary_error == nil
        end)

      refute log =~ "read failed"
    end
  end

  # ===========================================================================
  # Reads: an outage is never "not found"
  # ===========================================================================

  describe "get_*_result" do
    test "an outage is :unavailable, a missing or malformed id is :not_found (and logs nothing)" do
      driver = seeded_driver()
      scope = BrokerLive.broker_scope(@org)

      assert {:ok, %{id: id}} = Reads.get_driver_result(scope, driver.id)
      assert id == driver.id

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Reads.get_driver_result(scope, "not-a-uuid")
          assert {:error, :not_found} = Reads.get_driver_result(scope, Ecto.UUID.generate())
          assert {:error, :not_found} = Reads.get_settlement_result(scope, "../etc/passwd")
          assert {:error, :not_found} = Reads.get_load_result(scope, nil)
        end)

      refute log =~ "read failed"

      break_select!("drv_driver", "drv_status")
      log = capture_log(fn -> assert {:error, :unavailable} = Reads.get_driver_result(scope, driver.id) end)
      assert log =~ "read=driftwood_get_driver"
      assert log =~ "cause="
      refute log =~ "Pat"

      # The legacy shim keeps its old shape for callers that have not moved.
      assert quiet(fn -> Reads.get_driver(scope, driver.id) end) == :error
    end

    test "dispatch_decision reports an outage as :unavailable, not 'driver not found'" do
      driver = seeded_driver()
      assert {:ok, _} = BrokerLive.dispatch_decision(@org, driver.id)

      break_select!("drv_driver", "drv_status")
      assert {:error, :unavailable} = quiet(fn -> BrokerLive.dispatch_decision(@org, driver.id) end)

      socket =
        quiet(fn ->
          broker_event(broker_socket("roster"), "dispatch", %{"driver" => driver.id})
        end)

      flash = socket.assigns.flash["error"]
      assert flash =~ "Couldn't check that driver"
      refute flash =~ "driver not found"
    end

    test "edit_driver / edit_load / edit_settlement name an outage as a failed check, not 'not found'" do
      driver = seeded_driver()
      load = seeded_load()

      break_select!("drv_driver", "drv_status")
      break_select!("fop_opportunity", "fop_status")
      break_select!("stl_settlement", "stl_status")

      socket = broker_socket("roster")

      for {event, params, needle} <- [
            {"edit_driver", %{"driver" => driver.id}, "open that driver"},
            {"edit_load", %{"id" => load.id}, "open that load"},
            {"edit_settlement", %{"settlement" => Ecto.UUID.generate()}, "open that settlement"}
          ] do
        flash = quiet(fn -> broker_event(socket, event, params) end).assigns.flash["error"]
        assert flash =~ needle, "#{event}: #{inspect(flash)}"
        refute flash =~ "not found"
      end
    end

    test "POSITIVE CONTROL: a genuinely missing record is still 'not found'" do
      socket = broker_socket("roster")
      assert broker_event(socket, "edit_driver", %{"driver" => Ecto.UUID.generate()}).assigns.flash["error"] == "driver not found"
      assert broker_event(socket, "edit_load", %{"id" => "nope"}).assigns.flash["error"] == "load not found"
    end
  end

  # ===========================================================================
  # Writes: a failed write tells the user, with outage copy and not denial/validation copy
  # ===========================================================================

  describe "load writes" do
    test "create_load on a failing table is {:error, :unavailable}, not a 'reference is required' changeset" do
      break_writes!("fop_opportunity")

      log = capture_log(fn -> assert {:error, :unavailable} = BrokerLive.create_load(@org, %{"name" => "X", "status" => "open"}) end)
      assert log =~ "write failed write=driftwood_create_load"

      socket =
        quiet(fn ->
          socket = broker_socket("loads", new_load_form: Phoenix.Component.to_form(%{}, as: :load))
          broker_event(socket, "save_load", %{"load" => %{"name" => "X", "status" => "open"}})
        end)

      assert socket.assigns.load_error =~ "Couldn't create that load"
      refute socket.assigns.load_error =~ "reference is required"
    end

    test "POSITIVE CONTROL: a real validation refusal keeps the validation copy" do
      socket =
        broker_event(
          broker_socket("loads", new_load_form: Phoenix.Component.to_form(%{}, as: :load)),
          "save_load",
          %{"load" => %{"name" => "", "status" => "open"}}
        )

      assert socket.assigns.load_error =~ "a load reference is required"
    end

    test "update_load and delete_load on a failing table are outage copy; nothing is applied" do
      load = seeded_load()
      break_writes!("fop_opportunity")

      assert {:error, :unavailable} = quiet(fn -> BrokerLive.update_load(@org, load.id, %{"name" => "RENAMED", "status" => "won"}) end)
      assert {:error, :unavailable} = quiet(fn -> BrokerLive.delete_load(@org, load.id) end)

      socket =
        quiet(fn ->
          broker_event(broker_socket("loads", edit_load_id: load.id, edit_load_form: nil), "delete_load", %{"id" => load.id})
        end)

      assert socket.assigns.delete_load_error =~ "Couldn't delete that load"
      refute socket.assigns.delete_load_error == "Could not delete this load."

      ddl!("ALTER TABLE fop_opportunity DROP CONSTRAINT zz_p4_broken")
      assert [%{name: "BRL-P4 dry van"}] = Reads.load_board(BrokerLive.broker_scope(@org))
    end

    test "the Edit button opens the modal for a real load (the lane comes off the custom bag)" do
      load = seeded_load()

      socket = broker_event(broker_socket("loads"), "edit_load", %{"id" => load.id})

      assert socket.assigns.show_edit_load
      assert socket.assigns.edit_load_form.params["lane"] == "TX->CA"
    end
  end

  describe "driver and settlement form writes" do
    @driver_params %{
      "full_name" => %{"first" => "Nia", "last" => "Roadworth"},
      "cdl_number" => "CDL-P4-0002",
      "cdl_state" => "TX",
      "cdl_expiry" => "2031-01-01",
      "medical_card_expiry" => "2031-01-01",
      "eld_provider" => "samsara",
      "status" => "available"
    }

    defp new_driver_socket do
      scope = BrokerLive.broker_scope(@org)

      form =
        Driftwood.Freight.Driver
        |> AshPhoenix.Form.for_create(:create, scope: scope)
        |> Phoenix.Component.to_form()

      broker_socket("roster", new_driver_form: form, show_new_driver: true)
    end

    test "a driver insert that fails is a flash in outage copy, and the roster is not claimed saved" do
      break_writes!("drv_driver")

      socket = quiet(fn -> broker_event(new_driver_socket(), "save_new_driver", %{"form" => @driver_params}) end)

      assert socket.assigns.flash["error"] =~ "Couldn't save that driver"
      refute Map.has_key?(socket.assigns.flash, "info")
      assert socket.assigns.show_new_driver
    end

    test "POSITIVE CONTROL: a valid driver saves, and a real refusal stays a form error (no flash)" do
      saved = broker_event(new_driver_socket(), "save_new_driver", %{"form" => @driver_params})
      assert saved.assigns.flash["info"] == "Driver added."

      refused = broker_event(new_driver_socket(), "save_new_driver", %{"form" => Map.put(@driver_params, "status", "not-a-status")})
      refute Map.has_key?(refused.assigns.flash, "error")
      assert refused.assigns.show_new_driver
    end

    test "a settlement insert that fails is outage copy" do
      scope = BrokerLive.broker_scope(@org)

      form =
        Driftwood.Freight.Settlement
        |> AshPhoenix.Form.for_create(:create, scope: scope)
        |> Phoenix.Component.to_form()

      break_writes!("stl_settlement")

      socket =
        quiet(fn ->
          broker_event(broker_socket("settlements", new_settlement_form: form, show_new_settlement: true), "save_new_settlement", %{
            "form" => %{"linehaul_cents" => "1000", "status" => "draft", "currency" => "USD"}
          })
        end)

      assert socket.assigns.flash["error"] =~ "Couldn't save that settlement"
    end
  end

  # ===========================================================================
  # Operator impersonation console: panes fail alone, the gate and the reveal fail closed
  # ===========================================================================

  describe "operator impersonation console" do
    setup do
      s = Driftwood.DogfoodScenario.build(lane: "IL->TX", tier: "starter", mrr_cents: 120_000)
      op = Actor.new("op-p4-#{System.unique_integer([:positive])}", :operator_support)
      {:ok, _} = Impersonation.open(op, s.org_id, "ticket #4404: p4 honest reads")
      %{s: s, op: op}
    end

    defp op_load(op, s), do: OpLive.load(flash_socket(), op.id, s.org_id)

    defp op_html(socket), do: html(OpLive, socket.assigns)

    defp op_event(socket, name, params) do
      {:noreply, socket} = OpLive.handle_event(name, params, socket)
      socket
    end

    test "a failed roster is an error in the roster pane while the load board still renders; masked, no names", %{s: s, op: op} do
      break_select!("drv_driver", "drv_status")

      socket = quiet(fn -> op_load(op, s) end)
      rendered = op_html(socket)

      assert socket.assigns.impersonating
      assert socket.assigns.drivers_error == :unavailable
      assert socket.assigns.loads_error == nil
      assert_error_state(rendered)
      refute rendered =~ "driver-row"
      refute rendered =~ "vt_"
      # the load board is another read and still renders
      assert rendered =~ "Load board"
      assert rendered =~ "load-row"
    end

    test "POSITIVE CONTROL: the same console with healthy tables renders masked rows and no error", %{s: s, op: op} do
      socket = op_load(op, s)
      rendered = op_html(socket)

      assert socket.assigns.drivers_error == nil
      refute rendered =~ "error-state"
      assert rendered =~ "driver-row"
      assert rendered =~ "••••"
    end

    test "a failed load board does not hide the roster", %{s: s, op: op} do
      break_select!("fop_opportunity", "fop_status")

      socket = quiet(fn -> op_load(op, s) end)
      rendered = op_html(socket)

      assert socket.assigns.loads_error == :unavailable
      assert_error_state(rendered)
      assert rendered =~ "driver-row"
    end

    test "a failed reveal-window lookup is 'unknown', not 'no window is open'; it recovers on retry", %{s: s, op: op} do
      driver_id = to_string(s.compliant_driver_id)
      {:ok, req} = Grants.request(%{subject_id: driver_id, requestor_id: op.id, reason: "ticket #4404 verify"})
      {:ok, _} = Grants.approve(req, %{granted_by: "distinct-reviewer-p4", window_minutes: 15})

      healthy = op_load(op, s)
      assert [_] = healthy.assigns.reveal_windows
      assert op_html(healthy) =~ "Privileged reveal window OPEN"

      break_select!("rvg_reveal_grant", "rvg_expires_at")
      socket = quiet(fn -> op_load(op, s) end)
      rendered = op_html(socket)

      assert socket.assigns.reveal_windows_error == :unavailable
      assert rendered =~ "reveal-windows-unknown"
      assert rendered =~ "couldn&#39;t check whether a reveal window is open" or rendered =~ "couldn't check whether a reveal window is open"
      refute rendered =~ "Privileged reveal window OPEN"
    end

    test "a reveal that cannot check its grant fails CLOSED with outage copy; a real denial keeps denial copy", %{s: s, op: op} do
      driver_id = to_string(s.compliant_driver_id)
      socket = op_load(op, s)

      # a real denial (no grant): denial copy
      denied = op_event(socket, "reveal", %{"driver" => driver_id})
      assert denied.assigns.flash["error"] == "reveal denied — no active second-party grant"
      assert denied.assigns.revealed == %{}

      # the grant lookup itself fails: closed (nothing revealed), and NOT the denial copy
      {:ok, req} = Grants.request(%{subject_id: driver_id, requestor_id: op.id, reason: "ticket #4404 verify"})
      {:ok, _} = Grants.approve(req, %{granted_by: "distinct-reviewer-p4", window_minutes: 15})
      break_select!("rvg_reveal_grant", "rvg_expires_at")

      log = capture_log(fn -> send(self(), {:socket, op_event(socket, "reveal", %{"driver" => driver_id})}) end)
      assert_received {:socket, failed}

      assert failed.assigns.flash["error"] =~ "Couldn't check the reveal grant"
      assert failed.assigns.revealed == %{}
      assert log =~ "driftwood_reveal_cdl"
      refute log =~ "CDL-"
    end

    test "a reveal REQUEST that cannot be filed says so (outage copy), not 'reveal denied'", %{s: s, op: op} do
      driver_id = to_string(s.compliant_driver_id)
      socket = op_load(op, s)
      break_select!("rvq_reveal_request", "rvq_status")

      failed = quiet(fn -> op_event(socket, "request_reveal", %{"driver" => driver_id}) end)

      assert failed.assigns.request_notice =~ "Couldn't file the reveal request"
    end

    test "masked_cdl: a malformed id is :not_found with no log; a failing read is :unavailable, never :not_found", %{s: s} do
      log = capture_log(fn -> assert {:error, :not_found} = Driftwood.OperatorReveal.reveal_cdl("op-1", "not-a-uuid") end)
      refute log =~ "read failed"

      break_select!("drv_driver", "drv_cdl_expiry")
      driver_id = to_string(s.compliant_driver_id)
      assert {:error, :unavailable} = quiet(fn -> Driftwood.OperatorReveal.reveal_cdl("op-1", driver_id) end)
    end

    test "a failing directory read shows the org id it was given and is reported, never a name it could not look up", %{s: s, op: op} do
      break_select!("doo_org", "doo_name")

      log = capture_log(fn -> send(self(), {:socket, op_load(op, s)}) end)
      assert_received {:socket, socket}

      assert socket.assigns.org_name == s.org_id
      assert log =~ "driftwood_org_name"
    end
  end

  # ===========================================================================
  # Landing controller: a failed membership lookup is not "no org"
  # ===========================================================================

  describe "landing" do
    alias Driftwood.Operator.{AuthToken, Credential, Membership, Org, Session, User}
    alias Samen.Auth.SessionCreate
    alias Samen.Identity.Register

    @secret_key_base String.duplicate("b", 64)

    defp landing_conn(raw_token) do
      opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

      conn(:get, "/")
      |> Map.put(:secret_key_base, @secret_key_base)
      |> Plug.Session.call(opts)
      |> fetch_session()
      |> Samen.Web.Auth.put_session_token(raw_token)
    end

    test "a membership lookup that fails is a 503, not a redirect to the operator console; the healthy path still lands" do
      prev = Application.get_env(:samen_core, :delivery_env)
      Application.put_env(:samen_core, :delivery_env, :test)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :delivery_env, prev), else: Application.delete_env(:samen_core, :delivery_env) end)

      {:ok, tenant} =
        Register.register(
          %{
            org_name: "P4 Landing Co #{System.unique_integer([:positive])}",
            first_name: "Ada",
            last_name: "Lovelace",
            email: "p4-landing-#{System.unique_integer([:positive])}@example.test",
            password: "correct horse battery staple"
          },
          %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Driftwood.Repo}
        )

      {:ok, _session, raw} = SessionCreate.create(%{session: Session, org: Org, membership: Membership, user: User}, tenant.credential.id)

      # POSITIVE CONTROL: healthy lookup lands on the tenant's workspace
      ok = DriftwoodWeb.PageController.index(landing_conn(raw), %{})
      assert ok.status in 300..399
      assert get_resp_header(ok, "location") == ["/broker?org=#{tenant.org.id}"]

      break_select!("dos_session", "dos_token_digest")
      log = capture_log(fn -> send(self(), {:conn, DriftwoodWeb.PageController.index(landing_conn(raw), %{})}) end)
      assert_received {:conn, conn}

      assert conn.status == 503
      assert conn.resp_body =~ "couldn't check your workspace"
      assert get_resp_header(conn, "location") == []
      assert log =~ "driftwood_tenant_landing"
    end
  end

  # ===========================================================================
  # Seeds: a failed probe or step is a failed seed, not a skipped or repeated one
  # ===========================================================================

  describe "seeds" do
    test "OperatorSeeds.seed/0 is re-runnable: a second run on a seeded database adds nothing" do
      assert :ok = Driftwood.OperatorSeeds.seed()
      before = Driftwood.Repo.aggregate(Driftwood.Operator.Org, :count)
      assert before > 1

      assert :ok = Driftwood.OperatorSeeds.seed()
      assert Driftwood.Repo.aggregate(Driftwood.Operator.Org, :count) == before
    end

    test "a failing 'account already seeded?' probe raises instead of answering 'yes, skip it'" do
      assert :ok = Driftwood.OperatorSeeds.seed()
      break_select!("doo_org", "doo_slug")

      assert_raise Ash.Error.Unknown, fn -> Driftwood.OperatorSeeds.seed() end
    end

    test "an interrupted earlier run (accounts missing, desk agent gone) is an error, not a silent 'nothing to do'" do
      assert :ok = Driftwood.OperatorSeeds.seed()
      ddl!("UPDATE dqg_agent SET dqg_handle = 'renamed-by-test' WHERE dqg_handle = 'pnakamura'")
      ddl!("DELETE FROM doo_org WHERE doo_slug = 'b1112d00-0000-4000-8000-000000000001'")

      error = assert_raise RuntimeError, fn -> Driftwood.OperatorSeeds.seed() end
      assert error.message =~ "desk agent"
      assert error.message =~ "interrupted"
    end

    test "demo_all: a failing 'marketing already seeded?' probe raises instead of re-seeding or skipping" do
      org = Ecto.UUID.generate()
      :ok = Driftwood.Seeds.run(org)
      assert ^org = Driftwood.Seeds.demo_all(org)

      break_select!("fmc_campaign", "fmc_org_id")
      assert_raise Ash.Error.Unknown, fn -> Driftwood.Seeds.demo_all(org) end
    end
  end
end
