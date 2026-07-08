defmodule Samen.Web.OperatorRenderTest do
  @moduledoc """
  Tests the operator-plane surfaces: the token-blind aggregate LiveView renders its chrome
  (banner + ⊘ suppression) and a host-supplied projection, and the `/ui-kit` catalog renders.
  These are the operator-plane STUB surfaces (ADR-009 §5.3) — the aggregate has no PII by
  construction (no pii_ column to mask), so the proof is the token-blind chrome + ⊘.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Mount
  alias Samen.Web.Plane

  # A host aggregate loader returning a token-blind projection with one suppressed cohort.
  def sample_aggregate do
    %{
      metrics: [%{label: "Portfolio MRR", value: {:money, 1_240_000}, sub: "over tenants"}],
      groups: [
        %{
          id: "mrr",
          title: "MRR by tier",
          columns: ["Tier", "Tenants", "MRR"],
          rows: [
            ["growth", 4, {:money, 800_000}],
            ["scale", %Samen.Aggregate.Suppressed{reason: :k_anonymity}, %Samen.Aggregate.Suppressed{reason: :k_anonymity}]
          ]
        }
      ],
      suppressed_count: 1
    }
  end

  defp render_html(module, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "the token-blind aggregate LiveView renders the banner + a host projection with ⊘" do
    mount =
      Mount.new(:aggregate, Some.Host.Aggregate, Some.Host.Repo,
        plane: Plane.operator("op", "portfolio"),
        labels: %{aggregate_loader: {__MODULE__, :sample_aggregate, []}}
      )

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Samen.Web.Operator.AggregateLive.load()

    html = render_html(Samen.Web.Operator.AggregateLive, socket.assigns)

    # Token-blind chrome present.
    assert html =~ ~s(class="tb-bar")
    assert html =~ "no pii_ column"
    # Host projection rendered.
    assert html =~ "MRR by tier"
    assert html =~ "growth"
    # Suppressed cohort renders ⊘, not the underlying value.
    assert html =~ "⊘"
    assert html =~ "k-anonymity floor"
  end

  test "the aggregate LiveView renders structurally even with no loader (bare stub)" do
    mount = Mount.new(:aggregate, Some.Host.Aggregate, Some.Host.Repo, plane: Plane.operator("op", "p"))

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Samen.Web.Operator.AggregateLive.load()

    html = render_html(Samen.Web.Operator.AggregateLive, socket.assigns)

    assert html =~ ~s(class="app")
    assert html =~ ~s(class="tb-bar")
    assert html =~ "No aggregate projection wired"
  end

  test "the /ui-kit living catalog renders every component group" do
    html = render_html(Samen.Web.UIKitLive, %{})

    assert html =~ "Samen.UI catalog"
    assert html =~ ~s(class="pill ok")
    assert html =~ ~s(class="metrics")
    assert html =~ ~s(class="mask-bar")
    assert html =~ ~s(class="tb-bar")
  end
end
