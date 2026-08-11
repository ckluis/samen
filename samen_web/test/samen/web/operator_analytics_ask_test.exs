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

  # --- PP-14: the ask-scope is built from the VERIFIED operator principal, not a literal tag ---

  test "PP-14: ask_scope carries the REAL operator principal (OperatorPlane.Actor), not a synthetic tag" do
    socket =
      socket()
      |> Phoenix.Component.assign(:samen_operator_id, "op-user-42")
      |> Phoenix.Component.assign(:samen_operator_role, :operator_admin)

    scope = AnalyticsLive.ask_scope(socket)

    # A first-class platform actor with the resolved role + authenticated id — NOT the old
    # role-less `%{plane: :operator}` literal. T144 authorizes from a verified principal.
    assert %Samen.Scope{actor: %Samen.OperatorPlane.Actor{id: "op-user-42", operator_role: :operator_admin}} =
             scope
  end

  test "PP-14 fail-closed: ask_scope with NO resolved operator role is NOT a platform-caller actor" do
    # No `:samen_operator_role` assigned (route authz would have halted, but defense-in-depth):
    # the scope must fail CLOSED to a non-operator actor T144 refuses — NEVER the synthetic
    # `%{plane: :operator}` tag that would authorize the cross-tenant read with no principal.
    # (Runtime `Map.get` reads, not struct-literal matches, so the guarantee is checked on the
    # actual value regardless of the compiler's inferred return type.)
    actor = AnalyticsLive.ask_scope(socket()).actor

    # A plain tenant-plane actor — NOT a first-class `OperatorPlane.Actor`, and NOT the synthetic
    # `%{plane: :operator}` tag. T144's `platform_actor?/1` accepts only an `OperatorPlane.Actor`,
    # `%{kind: :operator}`, or `%{plane: :operator}`; this exact shape is refused fail-closed.
    refute match?(%Samen.OperatorPlane.Actor{}, actor)
    assert actor == %{kind: :tenant, plane: :tenant}
  end
end
