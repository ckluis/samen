defmodule Samen.Web.OperatorAnalyticsAskTest do
  @moduledoc """
  T149 B2b — the operator AnalyticsLive "ask" box wires the EXISTING kernel
  `Samen.AI.Analytics.ask/4` into the operator UI (augmenting the static SEED). This host
  wires NO `:analytics_ask_resource`, so the box is UNWIRED — the proof here is the honest
  fail-closed UI (never a faked narration). The REAL narration path (Provider.Fake over a real
  aggregate projection) is proven on the driftwood vertical, which wires the resource.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.AnalyticsLive

  defp socket do
    mount = build_operator_mount(Ash.UUID.generate())

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> AnalyticsLive.load()
  end

  test "the ask box renders and reports UNWIRED when no aggregate projection is set" do
    html = render_html(AnalyticsLive, socket().assigns)

    assert html =~ ~s(id="analytics-ask-form")
    assert html =~ ~s(id="analytics-ask-input")
    assert html =~ ~s(id="ask-unwired")
  end

  test "asking with no aggregate projection wired surfaces the honest not-configured state" do
    {:noreply, socket} = AnalyticsLive.handle_event("ask", %{"q" => "Which tier drives MRR?"}, socket())

    assert socket.assigns.ask_result == {:error, :not_configured}

    html = render_html(AnalyticsLive, socket.assigns)
    assert html =~ "ask-honest"
    assert html =~ "not configured"
    # Fail-honest: no fabricated narration.
    refute html =~ "ask-narration"
  end

  test "an empty question is refused honestly (no aggregate read attempted)" do
    {:noreply, socket} = AnalyticsLive.handle_event("ask", %{"q" => "   "}, socket())
    assert socket.assigns.ask_result == {:error, :empty}
    assert render_html(AnalyticsLive, socket.assigns) =~ "Enter a question"
  end
end
