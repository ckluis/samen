defmodule Samen.Web.LiveWideEventsE2ETest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 1) — the LiveView wide events END-TO-END: a REAL framework LiveView
  (the CRM contacts surface) mounted through a REAL router + endpoint
  (`Samen.WebTest.SecurityEndpoint`) on an ARMED host, with `Samen.Observability.LiveTelemetry`
  attached exactly as `Samen.Observability.child_specs/2` attaches it.

  The samen_core unit suite (`samen_core/test/observability/live_telemetry_test.exs`) drives the
  handler with synthetic metadata; this suite proves it against what Phoenix really emits:

    * a real dead render through the router fires ONE `mount` and ONE `handle_params` event,
      each bounded, with the authenticated org as `tenant_id` and the principal's HMAC
      pseudonym as `actor_id` (never the principal);
    * `handle_event` against the REAL framework view module: `event` is ContactsLive's own
      literal (`:validate_new`), typed form params (an email) never reach the event, and an
      event the view does not handle is `:other` and never becomes an atom (R2).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Observability.LiveTelemetry
  alias Samen.Web.Auth
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint
  @collector {__MODULE__, :collector}

  def collect(_event, measurements, metadata, test_pid),
    do: send(test_pid, {:wide_event, Map.merge(metadata, measurements)})

  @secret "e2e-typed-secret@example.test"

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_orgs = Application.get_env(:samen_web, :security_test_authorized_orgs, %{})

    LiveTelemetry.detach()
    :ok = LiveTelemetry.attach()

    :ok =
      :telemetry.attach(
        @collector,
        Samen.WideEvent.telemetry_event(),
        &__MODULE__.collect/4,
        self()
      )

    on_exit(fn ->
      LiveTelemetry.detach()
      :telemetry.detach(@collector)

      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      Application.put_env(:samen_web, :security_test_authorized_orgs, prev_orgs)
    end)

    org = Ash.UUID.generate()
    principal = Ash.UUID.generate()

    SecurityHost.revoke_all!()
    SecurityHost.arm!()
    SecurityHost.grant!(principal, [org])
    {:ok, _} = Samen.Kms.adapter().generate_subject_key(principal)

    %{org: org, principal: principal}
  end

  defp signed_in_conn(user_id) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_user_key(), user_id)
  end

  defp drain(acc \\ []) do
    receive do
      {:wide_event, ev} -> drain([ev | acc])
    after
      150 -> Enum.reverse(acc)
    end
  end

  test "a real dead render emits ONE mount + ONE handle_params event, bounded, tenant + actor",
       ctx do
    html =
      signed_in_conn(ctx.principal) |> get("/crm/contacts?org=#{ctx.org}") |> html_response(200)

    assert html =~ "phx-"

    events = drain()
    assert [mount] = Enum.filter(events, &(&1.callback == :mount))
    assert [params] = Enum.filter(events, &(&1.callback == :handle_params))

    assert mount.action == :live_view
    assert mount.outcome == :ok
    assert mount.view == "Samen.Web.CRM.ContactsLive"
    assert mount.tenant_id == ctx.org

    {:ok, expected_actor} = Samen.WideEvent.for_subject(ctx.principal)
    assert mount.actor_id == expected_actor
    assert params.view == mount.view

    for ev <- events, do: refute(inspect(ev) =~ ctx.principal)
  end

  # samen_web carries no `lazy_html`, so a CONNECTED LiveView test (render_click/render_hook)
  # cannot run here. The handle_event metadata LiveView emits is `%{socket, event, params}`;
  # these two tests feed that shape with a REAL `%Phoenix.LiveView.Socket{}` for the REAL
  # ContactsLive module, so the event set is the framework view's own compiled literals.
  defp handle_event!(ctx, event, params) do
    socket = %Phoenix.LiveView.Socket{
      view: Samen.Web.CRM.ContactsLive,
      assigns: %{__changed__: %{}, org_id: ctx.org, samen_tenant_principal: ctx.principal}
    }

    :telemetry.execute(
      [:phoenix, :live_view, :handle_event, :stop],
      %{duration: System.convert_time_unit(3, :millisecond, :native)},
      %{socket: socket, event: event, params: params}
    )
  end

  test "a framework view's own event resolves to its literal; typed params never reach it", ctx do
    handle_event!(ctx, "validate_new", %{"contact" => %{"email" => @secret}})

    assert [ev] = drain()
    assert ev.event == :validate_new
    assert ev.callback == :handle_event
    assert ev.tenant_id == ctx.org
    refute inspect(ev) =~ @secret
  end

  test "R2: an event ContactsLive does not handle is :other and never becomes an atom", ctx do
    unknown = "zz_e2e_client_event_#{System.unique_integer([:positive])}"
    handle_event!(ctx, unknown, %{"email" => @secret})

    assert [ev] = drain()
    assert ev.event == :other
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end
end
