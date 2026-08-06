defmodule Driftwood.OperatorAnalyticsAskTest do
  @moduledoc """
  T149 B2b (driftwood side) — the operator AnalyticsLive "ask" box, wired here to the real
  aggregate-plane projection `Driftwood.Aggregate.MrrByTier` via the `:analytics_ask_resource`
  mount label, narrates a natural-language question through the EXISTING kernel
  `Samen.AI.Analytics.ask/4`. Keyless: driftwood wires NO AI provider, so `:test` uses the
  recording `Samen.AI.Provider.Fake` — the narration is REAL (a deterministic completion), never
  faked by the LiveView.
  """
  use Driftwood.DataCase, async: false

  alias Samen.Web.Operator.AnalyticsLive

  defp render_html(module, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # Wire the operator mount exactly as `samen_operator_routes` does for the analytics surface,
  # carrying the aggregate-projection label the router now sets.
  defp mount do
    Samen.Web.Mount.new(:operator, Driftwood.Operator, Driftwood.Repo,
      plane: Samen.Web.Plane.tenant(),
      labels: %{
        operator_org_id: "0f000000-0000-4000-8000-0000000000aa",
        analytics_ask_resource: Driftwood.Aggregate.MrrByTier
      }
    )
  end

  defp socket do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount())
    |> AnalyticsLive.load()
  end

  setup do
    # A cross-tenant MRR-by-tier cohort with tenant_count above the k-anon floor, so a real
    # number is narratable (not suppressed to ⊘). Mirrors Driftwood.Aggregate.Rebuild's INSERT.
    Repo.query!(
      "INSERT INTO dtq_mrr_by_tier (dtq_id, dtq_tier, dtq_tenant_count, dtq_mrr_cents, dtq_refreshed_at) " <>
        "VALUES (gen_random_uuid(), 'growth', 8, 500000, now())"
    )

    :ok
  end

  test "the ask box is WIRED (no unwired notice) when the host sets :analytics_ask_resource" do
    html = render_html(AnalyticsLive, socket().assigns)
    assert html =~ ~s(id="analytics-ask-form")
    refute html =~ ~s(id="ask-unwired")
  end

  test "asking a question narrates over the real aggregate projection (Provider.Fake, keyless)" do
    {:noreply, socket} =
      AnalyticsLive.handle_event("ask", %{"q" => "Which plan tier drives the most MRR?"}, socket())

    assert {:ok, %Samen.AI.Completion{text: text}} = socket.assigns.ask_result
    assert is_binary(text) and byte_size(text) > 0

    html = render_html(AnalyticsLive, socket.assigns)
    # The narration renders (not the honest fail state).
    assert html =~ "ask-narration"
    refute html =~ "not configured"
  end
end
