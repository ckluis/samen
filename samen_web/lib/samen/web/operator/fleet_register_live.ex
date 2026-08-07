defmodule Samen.Web.Operator.FleetRegisterLive do
  @moduledoc """
  J1 — register a mode-A app / mint a mode-B enrollment token
  (`/operator/fleet/register`, ADR-044 §4.2/§4.3, T84b). Admin-gated
  (`roles[:fleet] == :operator_admin`, §6.3). A minimal admin surface over the
  registry mutations T82 already built (`Samen.Fleet.Registry.register_app/3`,
  `mint_enrollment_token/3`) — no vertical-specific chrome, framework-owned.

  The mode-A secret / mode-B token is shown EXACTLY ONCE (§4.2 step 2 / §4.3
  step 1) — `@revealed` is a one-shot flash assign, never persisted to the
  socket beyond the render that follows the mutation.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live, only: [assign_mount: 2, operator_sidebar: 1]

  alias Samen.Fleet.{AdminActor, Registry}
  alias Samen.Web.Operator.Fleet, as: FleetHelpers

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)

    case FleetHelpers.gate(socket.assigns[:samen_mount], session) do
      {:ok, ctx} ->
        {:ok,
         socket
         |> assign(
           fleet_ctx: ctx,
           revealed: nil,
           error: nil,
           slug_form: to_form(%{"slug" => "", "display_name" => "", "base_url" => ""}, as: :register),
           token_form: to_form(%{"app_slug" => "", "display_name" => ""}, as: :enroll)
         )}

      :denied ->
        {:ok, redirect(socket, to: FleetHelpers.login_path(socket.assigns[:samen_mount]))}
    end
  end

  @impl true
  def handle_event("register_app", %{"register" => params}, socket) do
    with_admin(socket, fn ns, actor ->
      case Registry.register_app(ns, %{slug: params["slug"], display_name: params["display_name"], base_url: present(params["base_url"])}, actor) do
        {:ok, %{raw_secret: secret, app: app}} ->
          {:noreply, assign(socket, revealed: {:secret, app.slug, secret}, error: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, error: inspect(reason))}
      end
    end)
  end

  def handle_event("mint_token", %{"enroll" => params}, socket) do
    with_admin(socket, fn ns, actor ->
      case Registry.mint_enrollment_token(ns, %{app_slug: params["app_slug"], display_name: params["display_name"]}, actor) do
        {:ok, %{raw_token: token}} ->
          {:noreply, assign(socket, revealed: {:token, params["app_slug"], token}, error: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, error: inspect(reason))}
      end
    end)
  end

  defp with_admin(socket, fun) do
    %{admin?: admin?, namespace: namespace, principal_id: principal_id} = socket.assigns.fleet_ctx

    cond do
      not admin? -> {:noreply, assign(socket, error: "Only roles[:fleet] == :operator_admin may register/enroll.")}
      is_nil(namespace) -> {:noreply, assign(socket, error: "No fleet_namespace configured on this mount.")}
      true -> fun.(namespace, AdminActor.new(principal_id))
    end
  end

  defp present(""), do: nil
  defp present(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-register">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:fleet} />
        </:sidebar>

        <.topbar title="Register / enroll" crumbs={["Operator plane", "Fleet", "Register"]} />

        <div class="wrap">
          <div :if={!@fleet_ctx.admin?} class="card" id="register-not-admin" style="padding:16px 20px">
            Read-only — `roles[:fleet] == :operator_admin` is required to register an app or mint an enrollment token.
          </div>

          <div :if={@error} class="card form-error" id="register-error" style="padding:10px 14px;color:var(--bad,#b91c1c)">
            {@error}
          </div>

          <div :if={@revealed} class="card" id="revealed-secret" style="padding:16px 20px">
            <strong>Shown once — copy it now:</strong>
            <pre>{elem(@revealed, 2)}</pre>
          </div>

          <div :if={@fleet_ctx.admin?} class="gtitle" style="margin-top:14px"><h3>Mode A — register with a shared secret</h3></div>
          <.simple_form :if={@fleet_ctx.admin?} :let={f} for={@slug_form} id="register-form" phx-submit="register_app">
            <.form_field field={f[:slug]} label="Slug" placeholder="pawchart" />
            <.form_field field={f[:display_name]} label="Display name" placeholder="PawChart" />
            <.form_field field={f[:base_url]} label="Base URL (optional)" placeholder="https://pawchart.example.com" />
            <:actions>
              <.button variant="primary" type="submit">Register</.button>
            </:actions>
          </.simple_form>

          <div :if={@fleet_ctx.admin?} class="gtitle" style="margin-top:22px"><h3>Mode B — mint an enrollment token</h3></div>
          <.simple_form :if={@fleet_ctx.admin?} :let={f} for={@token_form} id="enroll-form" phx-submit="mint_token">
            <.form_field field={f[:app_slug]} label="Slug" placeholder="pawchart" />
            <.form_field field={f[:display_name]} label="Display name" placeholder="PawChart" />
            <:actions>
              <.button variant="primary" type="submit">Mint token</.button>
            </:actions>
          </.simple_form>
        </div>
      </.app_shell>
    </div>
    """
  end
end
