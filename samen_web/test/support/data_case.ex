defmodule Samen.WebTest.DataCase do
  @moduledoc """
  ExUnit case template for `samen_web`'s DB-backed render tests. Checks out the SQL sandbox
  on the scratch `samen_web_test` repo and provides `build_mount/2` — the framework mount
  helper the render tests use to mount a LiveView on a given plane.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Samen.WebTest.Repo
      alias Samen.WebTest.Seeds
      import Samen.WebTest.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Samen.WebTest.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, {:shared, self()})
    :ok
  end

  @doc """
  Build a `Samen.Web.Mount` for the test host's given scope on a plane.

  `scope_kind` is `:crm | :billing | :support`; `plane` is `:tenant` (default) or
  `:operator`. For the operator plane, `target_org_id` is required (the tenant org being
  impersonated).
  """
  def build_mount(scope_kind, opts \\ []) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator(
            "op-1",
            Keyword.fetch!(opts, :target_org_id),
            "test-session"
          )

        _ ->
          Samen.Web.Plane.tenant()
      end

    # The Marketing mount carries the CRM namespace on its labels so the Leads lens
    # (`Samen.Web.Marketing.LeadsLive`) can derive a CRM-kind mount and read contacts.
    labels =
      case scope_kind do
        :marketing -> %{crm_namespace: Samen.WebTest.Crm}
        _ -> nil
      end

    Samen.Web.Mount.new(scope_kind, namespace(scope_kind), Samen.WebTest.Repo, plane: plane, labels: labels)
  end

  @doc "The session map a framework LiveView expects (mimics the router's live_session)."
  def mount_session(mount) do
    %{"samen_mount" => Samen.Web.Mount.to_session(mount)}
  end

  @doc """
  Render a framework LiveView to an HTML string, on a given `mount` + `params`.

  Mirrors the established driftwood harness (`crm_ui_test.exs`): build a `%Socket{}` with the
  mount assigned (as the router's `live_session` session would), call the LiveView's `load/*`
  to populate assigns, then render `render/1` to HTML. This exercises the SAME code path the
  real mounted route runs, without booting an Endpoint. `load_args` are the positional args
  the module's `load/*` takes AFTER the socket (e.g. `[org_id]` for most pages,
  `[org_id, ticket_id]` for the ticket detail).
  """
  def render_live(module, mount, load_args) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> then(&apply(module, :load, [&1 | load_args]))

    render_html(module, socket.assigns)
  end

  @doc "Render a LiveView module's `render/1` for the given assigns to an HTML string."
  def render_html(module, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  Build a `Samen.Web.Mount` for the OPERATOR workspace (ADR-010) — `scope_kind: :operator`,
  TENANT plane (the operator org over its own book of business, PII clear), with the
  `operator_org_id` threaded on the labels so `Samen.Web.Operator.org_id/1` resolves it.
  """
  def build_operator_mount(operator_org_id, opts \\ []) do
    labels = Keyword.get(opts, :labels, %{}) |> Map.put(:operator_org_id, operator_org_id)

    Samen.Web.Mount.new(
      :operator,
      Samen.WebTest.Operator,
      Samen.WebTest.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: labels
    )
  end

  defp namespace(:crm), do: Samen.WebTest.Crm
  defp namespace(:billing), do: Samen.WebTest.Billing
  defp namespace(:support), do: Samen.WebTest.Support
  defp namespace(:marketing), do: Samen.WebTest.Marketing
end
