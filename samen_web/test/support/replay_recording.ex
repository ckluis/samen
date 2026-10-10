defmodule Samen.WebTest.ReplayRecording do
  @moduledoc """
  Records a REAL replay session for the player tests (ADR-052 P3) with the REAL P2 recorder:
  the connected `Samen.Web.CRM.ContactsLive` over the vault-routed `Samen.WebTest.Crm.Person`,
  driven through the real `Samen.Web.TenantAuthz` on_mount (which attaches
  `Samen.Web.Replay.Recorder`), LiveView's own `Phoenix.LiveView.Lifecycle` runners and the
  `[:phoenix, :live_view, :handle_event, :start]` telemetry — the same harness as
  `replay_recorder_test.exs` (samen_web carries no `lazy_html`, so a connected
  `Phoenix.LiveViewTest` session cannot run). When the process exits the monitor persists the
  session; `record_contacts!/2` returns its id.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Phoenix.LiveView.Lifecycle
  alias Samen.Replay
  alias Samen.Replay.Monitor
  alias Samen.Web.CRM.ContactsLive

  @doc "Start the capture plane with the `samen.replay` flag ON for `orgs`."
  def start_capture!(orgs) do
    config = %{
      enabled: true,
      rollout_pct: 0,
      stage: :ga,
      variants: %{},
      target_rules: [%{"attribute" => "org_id", "op" => "in", "values" => orgs, "then" => "allow"}]
    }

    start_supervised!({Replay.Supervisor, [flag_opts: [loader: fn "samen.replay" -> {:ok, config} end]]})
    :ok
  end

  @doc """
  Record one ContactsLive session of `org` on the tenant-plane CRM `mount`: mount → params →
  render → a `new_contact` event → render. Returns the persisted replay session id.
  """
  def record_contacts!(org, mount) do
    {pid, ref} =
      spawn_monitor(fn ->
        socket =
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

        {:cont, socket} =
          Samen.Web.TenantAuthz.on_mount(
            :require_tenant,
            %{},
            %{"samen_mount" => Samen.Web.Mount.to_session(mount)},
            socket
          )

        socket = ContactsLive.load(Phoenix.Component.assign(socket, :org_id, org), org)
        uri = "http://localhost/crm/contacts?org=#{org}"
        {:cont, socket} = Lifecycle.handle_params(%{"org" => org}, uri, socket)
        socket = socket |> Lifecycle.after_render() |> clear()

        :telemetry.execute(
          [:phoenix, :live_view, :handle_event, :start],
          %{system_time: System.system_time()},
          %{socket: socket, event: "new_contact", params: %{}}
        )

        {:noreply, socket} = ContactsLive.handle_event("new_contact", %{}, socket)
        _ = socket |> Lifecycle.after_render() |> clear()
        _ = :sys.get_state(Monitor)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    :ok = Monitor.flush()

    %{rows: [[id]]} =
      Samen.WebTest.Repo.query!(
        "SELECT rps_id::text FROM replay_session WHERE rps_org_id = $1 ORDER BY rps_started_at DESC LIMIT 1",
        [Ecto.UUID.dump!(org)]
      )

    id
  end

  defp clear(socket), do: %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}
end
