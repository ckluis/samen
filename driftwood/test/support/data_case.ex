defmodule Driftwood.DataCase do
  @moduledoc "ExUnit case template for database-backed Driftwood tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Driftwood.Repo
      import Driftwood.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Driftwood.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Driftwood.Repo, {:shared, self()})

    # The reviewed non_pii! rows the pii_classify gate + destruction oracle rely on.
    :ok = Driftwood.NonPiiSetup.register_all()
    :ok
  end

  # ==========================================================================
  # ADR-009 — mounting the FRAMEWORK LiveViews over Driftwood's OWN scope resources.
  #
  # The inherited CRM/Billing/Support UI now lives in samen_web (`Samen.Web.{CRM,Billing,
  # Support}`), mounted by DriftwoodWeb.Router over `Driftwood.{Crm,Billing,Support}`. These
  # helpers build the SAME `Samen.Web.Mount` the router builds (namespace → resources, repo,
  # plane) and render a framework LiveView through it — exercising the exact code path the
  # mounted route runs, on either plane, over Driftwood's materialized rows. This is how the
  # driftwood-side masking smokes (tenant clear / operator ••••) hit the mounted framework.
  # ==========================================================================

  @doc """
  Build a `Samen.Web.Mount` for a Driftwood scope on a plane — identical to what
  `DriftwoodWeb.Router`'s `samen_module_routes` produces. `scope_kind` is
  `:crm | :billing | :support`; `plane` is `:tenant` (default) or `:operator` (masked
  impersonation, `target_org_id` required).
  """
  def driftwood_mount(scope_kind, opts \\ []) do
    plane =
      case Keyword.get(opts, :plane, :tenant) do
        :operator ->
          Samen.Web.Plane.operator(
            "op-driftwood",
            Keyword.fetch!(opts, :target_org_id),
            "test-session"
          )

        _ ->
          Samen.Web.Plane.tenant()
      end

    # The Marketing mount carries the CRM namespace on its labels (as the router does) so the
    # Leads lens can derive a CRM-kind mount and read contacts by lifecycle_stage.
    labels =
      case scope_kind do
        :marketing -> %{crm_namespace: Driftwood.Crm}
        _ -> nil
      end

    Samen.Web.Mount.new(scope_kind, driftwood_namespace(scope_kind), Driftwood.Repo, plane: plane, labels: labels)
  end

  @doc """
  Render a framework LiveView over a Driftwood `mount` to an HTML string. Mirrors the
  samen_web + established driftwood harness: assign the mount (as the router's live_session
  would), call the LiveView's `load/*`, render `render/1`. `load_args` are the positional
  args after the socket (e.g. `[org_id]`, or `[org_id, ticket_id]` for the ticket detail).
  """
  def render_framework(module, mount, load_args, pre_assigns \\ %{}) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(Enum.to_list(pre_assigns))
      |> then(&apply(module, :load, [&1 | load_args]))

    socket.assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp driftwood_namespace(:crm), do: Driftwood.Crm
  defp driftwood_namespace(:billing), do: Driftwood.Billing
  defp driftwood_namespace(:support), do: Driftwood.Support
  defp driftwood_namespace(:marketing), do: Driftwood.Marketing
end
