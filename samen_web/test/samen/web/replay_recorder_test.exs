defmodule Samen.Web.ReplayRecorderTest do
  @moduledoc """
  ADR-052 §2.2 (P2) — the replay recorder END TO END over a REAL framework tenant LiveView
  (`Samen.Web.CRM.ContactsLive`) and a REAL vault-routed resource (`Samen.WebTest.Crm.Person`:
  `email` + `full_name` vaulted, seeded with distinctive plaintext sentinels).

  samen_web carries no `lazy_html`, so a connected `Phoenix.LiveViewTest` session cannot run.
  Each test instead plays the connected LiveView process itself, in a real process that
  exits: a CONNECTED `%Phoenix.LiveView.Socket{}` goes through the REAL
  `Samen.Web.TenantAuthz` `on_mount` (which attaches the recorder), the REAL `ContactsLive`
  load/`handle_event`, and LiveView's own `Phoenix.LiveView.Lifecycle` runners for
  `handle_params` / `after_render` — the exact functions `Phoenix.LiveView.Channel` calls —
  plus the `[:phoenix, :live_view, :handle_event, :start]` event LiveView emits. When the
  process exits, the monitor persists the session and the test scans the RAW Postgres rows.

    * R5 — no seeded plaintext anywhere in the persisted rows; Person's vault fields are Refs;
    * R7 — the typed create-form values are shape only;
    * R11 — capture is off unless the org's flag is on, and the operator plane never records
      (the recorder is not even attached there);
    * overhead — the per-render cost with capture ON, measured.
  """
  use Samen.WebTest.DataCase, async: false

  alias Phoenix.LiveView.Lifecycle
  alias Samen.FeatureFlags.Cache
  alias Samen.Replay
  alias Samen.Replay.{Capture, Monitor}
  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.Replay.Recorder

  @typed_email "typed.create.secret@example.test"
  @typed_first "Zebulon"
  @typed_last "Typedname"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, {:shared, self()})
    Cache.invalidate_all()

    on_exit(fn ->
      Cache.invalidate_all()
      Replay.erase_runtime_config()
      Capture.detach()
    end)

    seeded = Seeds.seed_all()
    %{seeded: seeded, org: seeded.org_id}
  end

  defp start_capture!(on_orgs, extra \\ []) do
    config = %{
      enabled: true,
      rollout_pct: 0,
      stage: :ga,
      variants: %{},
      target_rules: [
        %{"attribute" => "org_id", "op" => "in", "values" => on_orgs, "then" => "allow"}
      ]
    }

    opts = Keyword.merge([flag_opts: [loader: fn "samen.replay" -> {:ok, config} end]], extra)
    start_supervised!({Replay.Supervisor, opts})
    :ok
  end

  defp connected_socket(mount) do
    %Phoenix.LiveView.Socket{
      view: ContactsLive,
      router: Samen.WebTest.SecurityRouter,
      endpoint: Samen.WebTest.SecurityEndpoint,
      transport_pid: self(),
      private: %{lifecycle: %Lifecycle{}},
      assigns: %{__changed__: %{}, flash: %{}, live_action: :index}
    }
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
  end

  # The connected TenantAuthz on_mount — the hook every tenant live_session carries.
  defp on_mount!(socket, mount) do
    {:cont, socket} =
      Samen.Web.TenantAuthz.on_mount(:require_tenant, %{}, mount_session(mount), socket)

    socket
  end

  defp clear_changed(socket), do: %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}

  # Play one connected ContactsLive session in its own process, then wait for persistence.
  defp play(org, mount, fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        socket = mount |> connected_socket() |> on_mount!(mount)
        send(parent, {:attached?, Map.has_key?(socket.private, :samen_replay)})
        fun.(socket, org)
        _ = :sys.get_state(Monitor)
      end)

    assert_receive {:attached?, attached?}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
    assert reason == :normal, inspect(reason)
    :ok = Monitor.flush()
    attached?
  end

  # mount → handle_params → render → a typed create-form event → render.
  defp contacts_session(socket, org) do
    socket = ContactsLive.load(Phoenix.Component.assign(socket, :org_id, org), org)
    uri = "http://localhost/crm/contacts?org=#{org}"
    {:cont, socket} = Lifecycle.handle_params(%{"org" => org}, uri, socket)
    socket = socket |> Lifecycle.after_render() |> clear_changed()

    params = %{
      "form" => %{
        "full_name" => %{"first" => @typed_first, "last" => @typed_last},
        "emails" => %{"0" => %{"address" => @typed_email}}
      }
    }

    event!(socket, "new_contact", %{})
    {:noreply, socket} = ContactsLive.handle_event("new_contact", %{}, socket)
    socket = socket |> Lifecycle.after_render() |> clear_changed()
    event!(socket, "validate_new", params)
    {:noreply, socket} = ContactsLive.handle_event("validate_new", params, socket)
    socket |> Lifecycle.after_render() |> clear_changed()
  end

  defp event!(socket, event, params) do
    :telemetry.execute(
      [:phoenix, :live_view, :handle_event, :start],
      %{system_time: System.system_time()},
      %{socket: socket, event: event, params: params}
    )
  end

  defp raw do
    %{rows: frames} =
      Samen.WebTest.Repo.query!(
        "SELECT rpf_kind, rpf_payload::text FROM replay_frame ORDER BY rpf_seq"
      )

    %{rows: sessions} =
      Samen.WebTest.Repo.query!("SELECT row_to_json(s)::text FROM replay_session s")

    {frames, sessions}
  end

  defp text({frames, sessions}),
    do:
      Enum.map_join(frames, "\n", fn [k, p] -> k <> " " <> p end) <>
        Enum.join(List.flatten(sessions))

  test "R5/R7: a captured ContactsLive session persists Refs and shapes — no plaintext anywhere",
       ctx do
    start_capture!([ctx.org])
    mount = build_mount(:crm, [])

    # Positive control: the tenant-plane read the view holds DOES carry the sentinels.
    page_html = render_live(ContactsLive, mount, [ctx.org])
    assert page_html =~ Seeds.contact_email()

    assert play(ctx.org, mount, &contacts_session/2)

    {frames, _} = rows = raw()
    all = text(rows)
    kinds = Enum.map(frames, &hd/1)
    assert hd(kinds) == "mount"
    assert "params" in kinds
    assert Enum.count(kinds, &(&1 == "event")) == 2
    assert "render" in kinds
    assert List.last(kinds) == "exit"

    # The vault fields of the listed Person are recorded by reference.
    person_id = ctx.seeded.crm.person.id
    assert all =~ ~s("resource": "Samen.WebTest.Crm.Person")
    assert all =~ ~s("attribute": "emails")
    assert all =~ ~s("attribute": "full_name")
    assert all =~ person_id
    # The route TEMPLATE, never the concrete path; the view and its MD5.
    assert all =~ ~s("route": "/crm/contacts")
    assert all =~ ~s("view": "Samen.Web.CRM.ContactsLive")

    sentinels = [
      "Aurelia",
      "Sentinelson",
      Seeds.contact_email(),
      "aurelia.plaintext",
      @typed_email,
      "typed.create.secret",
      @typed_first,
      @typed_last
    ]

    for s <- sentinels, do: refute(all =~ s, "plaintext #{inspect(s)} reached the replay tables")
    refute all =~ "vt_"

    # R7: the typed form arrived as shape — key, type, length, class.
    [validate] =
      for [k, p] <- frames, k == "event", (d = Jason.decode!(p))["event"] == "validate_new", do: d

    assert inspect(validate) =~ ~s("class" => "email")
  end

  describe "R11 — off unless the org's flag is on; never on the operator plane" do
    test "flag OFF for the org: hooks detach, nothing is persisted", ctx do
      start_capture!([Ash.UUID.generate()])
      mount = build_mount(:crm, [])

      assert play(ctx.org, mount, fn socket, org ->
               socket = contacts_session(socket, org)
               # Decided OFF → every recorder hook detached.
               lifecycle = socket.private.lifecycle

               for stage <- [:handle_params, :after_render, :handle_info] do
                 refute Enum.any?(Map.fetch!(lifecycle, stage), &(&1.id == :samen_replay))
               end
             end)

      assert %{rows: [[0]]} = Samen.WebTest.Repo.query!("SELECT count(*) FROM replay_session")
    end

    test "the operator plane never attaches the recorder, even with the flag on", ctx do
      start_capture!([ctx.org])
      mount = build_mount(:crm, plane: :operator, target_org_id: ctx.org)
      refute play(ctx.org, mount, fn _socket, _org -> :ok end)
      assert %{rows: [[0]]} = Samen.WebTest.Repo.query!("SELECT count(*) FROM replay_session")
    end

    test "a DEAD (disconnected) mount never attaches", ctx do
      start_capture!([ctx.org])
      mount = build_mount(:crm, [])
      socket = %{connected_socket(mount) | transport_pid: nil}
      refute Map.has_key?(on_mount!(socket, mount).private, :samen_replay)
    end

    test "capture plane not running: TenantAuthz attaches nothing", _ctx do
      mount = build_mount(:crm, [])
      refute Map.has_key?(on_mount!(connected_socket(mount), mount).private, :samen_replay)
    end
  end

  test "framework list views declare their replay keep-list through the ListLive mixin" do
    keep = Replay.keep(ContactsLive)
    assert keep.params["sort"] == ["field"]
    assert keep.params["paginate"] == ["dir"]
    refute Map.has_key?(keep.params, "filter")
    # "sort" is handled by the mixin's hook, not a ContactsLive clause: the label comes from
    # the DECLARED literal, never the client string.
    assert Replay.event_label(ContactsLive, "sort") == "sort"
    assert Replay.event_label(ContactsLive, "Ada Lovelace") == "other"
  end

  test "a crash inside the recorder turns capture off and never reaches the LiveView", ctx do
    start_capture!([ctx.org])
    mount = build_mount(:crm, [])
    socket = mount |> connected_socket() |> on_mount!(mount)
    assert Map.has_key?(socket.private, :samen_replay)

    # A socket whose assigns are not a map: every recorder hook must survive it.
    broken = %{socket | assigns: :not_a_map}
    assert %Phoenix.LiveView.Socket{} = Recorder.after_render(broken)
    assert {:cont, %Phoenix.LiveView.Socket{}} = Recorder.handle_params(%{}, "http://x/", broken)
    assert {:cont, %Phoenix.LiveView.Socket{}} = Recorder.handle_info(:tick, broken)
  end

  @tag :perf
  test "overhead: per-render cost with capture ON (reported)", ctx do
    start_capture!([ctx.org], max_frames: 1_000_000, max_bytes: 4_000_000_000)
    mount = build_mount(:crm, [])
    parent = self()

    spawn_link(fn ->
      socket = mount |> connected_socket() |> on_mount!(mount)
      socket = ContactsLive.load(Phoenix.Component.assign(socket, :org_id, ctx.org), ctx.org)

      {:cont, socket} =
        Lifecycle.handle_params(%{"org" => ctx.org}, "http://localhost/crm/contacts", socket)

      socket = clear_changed(socket)
      # A full 50-row page of tenant-plane Person records (the list page size).
      page = socket.assigns.page
      page = %{page | items: List.duplicate(hd(page.items), 50)}

      assigns =
        Map.merge(socket.assigns, %{page: page, __changed__: %{page: true, list_state: true}})

      changed = %{socket | assigns: assigns}
      plain = %{changed | private: Map.put(changed.private, :lifecycle, %Lifecycle{})}

      runs = 2_000
      on = median_us(fn -> Lifecycle.after_render(changed) end, runs)
      off = median_us(fn -> Lifecycle.after_render(plain) end, runs)
      send(parent, {:overhead, on, off, length(page.items)})
    end)

    assert_receive {:overhead, on, off, rows}, 60_000

    IO.puts(
      "\n[replay overhead] after_render, #{rows}-row page changed: ON #{on} µs, OFF #{off} µs (median)"
    )

    assert on < 2_000
  end

  defp median_us(fun, runs) do
    times = for _ <- 1..runs, do: elem(:timer.tc(fun), 0)
    times |> Enum.sort() |> Enum.at(div(runs, 2))
  end
end
