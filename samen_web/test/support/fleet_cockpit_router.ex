defmodule Samen.WebTest.FleetCockpitRouter do
  @moduledoc """
  T84b — a REAL, compiled Phoenix router mounting `samen_operator_routes(...,
  fleet_cockpit: true)`, so RP-J-12 ("no un-gated path") can be proven by
  ENUMERATING `Phoenix.Router.routes/1` rather than by a hand-maintained list
  (ADR-044 §6.3: *"the property is discharged by a named, enumerating test
  rather than by this paragraph"*). This is the `fleet_cockpit_authz_test.exs`
  the ADR names as living in samen_web.

  No Endpoint is mounted here — `Phoenix.Router.routes/1` (and `on_mount`
  metadata) work directly off the compiled router module; a full
  Plug.Conn/Endpoint dispatch is not needed to enumerate route metadata.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/" do
    pipe_through(:browser)

    samen_operator_routes(Samen.WebTest.Operator,
      repo: Samen.WebTest.Repo,
      fleet_cockpit: true,
      fleet_namespace: Samen.WebTest.Fleet,
      labels: %{
        operator_authority: {Samen.WebTest.FleetCockpitRouter, :operator_role, []},
        fleet_authority: {Samen.WebTest.FleetCockpitRouter, :fleet_roles, []},
        fleet_resolution: {Samen.WebTest.FleetCockpitRouter, :fleet_scope, []}
      }
    )

    samen_fleet_routes(otp_app: :samen_web_fleet_cockpit_test_host)
    samen_fleet_ingest_routes(namespace: Samen.WebTest.Fleet)
  end

  # Minimal REAL (non-permissive) fixture resolvers — the point of this router
  # is route METADATA enumeration, but the resolvers are wired with genuine
  # deny-by-default shape (never a blanket `fn _ -> :operator_admin end`) so a
  # ConnTest-level dispatch through it, if a future test wants one, is not
  # accidentally permissive by construction.
  @doc false
  def operator_role(principal_id), do: Application.get_env(:samen_web, :fcr_operator_roles, %{})[principal_id]

  @doc false
  def fleet_roles(principal_id), do: Application.get_env(:samen_web, :fcr_fleet_roles, %{})[principal_id] || %{}

  @doc false
  def fleet_scope(principal_id), do: Application.get_env(:samen_web, :fcr_fleet_scope, %{})[principal_id] || :none
end
