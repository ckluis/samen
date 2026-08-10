defmodule Samen.Web.AI.AnalyticsAskHonestyTest do
  @moduledoc """
  Phase-6 T85 gate dogfood, M4 — the AI analytics ask-box was a DEAD TAB on the
  tenant plane: `AnalyticsLive` always rendered a live-looking "Ask an analytics
  question…" input + button, but `Samen.AI.Analytics.ask/4`'s T144 deny-by-default
  gate refuses EVERY tenant-plane question with `{:error, :unauthorized}`,
  deterministically, before any row is read. A tenant could type a question, hit
  Ask, and bounce — every single time.

  `Samen.Web.AI.Components.analytics_ask_offered?/1` gates the INPUT ITSELF (a UI
  posture, mirroring `Samen.Web.CRM.Live.writable?/1`'s tenant/operator split —
  NOT a security change): the tenant plane now renders the SAME honest
  `ai_result/1` `:unauthorized` card up front, with no input to type into; the
  operator plane still gets the real input. T144's actual gate is untouched —
  this file proves the UI posture is right AND that the underlying kernel gate
  still enforces (it was never weakened to make the honest-tenant-state land).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.AI.AnalyticsLive
  alias Samen.Web.Mount
  alias Samen.WebTest.Seeds

  defp ai_mount(org_id, plane, extra_labels \\ %{}) do
    plane_struct =
      case plane do
        :tenant -> Samen.Web.Plane.tenant()
        :operator -> Samen.Web.Plane.operator("op-1", org_id, "test-session")
      end

    labels = Map.merge(%{ai_aggregate_resource: Samen.WebTest.Crm.Company}, extra_labels)
    Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: plane_struct, labels: labels)
  end

  # ---------------------------------------------------------------------------
  describe "tenant plane — no dead-tab input, honest operator-only state" do
    test "the ask-box INPUT is not rendered on the tenant plane" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = ai_mount(org_id, :tenant)

      html = render_live(AnalyticsLive, mount, [org_id])

      refute html =~ ~s(id="ai-analytics-input")
      refute html =~ ~s(id="ai-analytics-ask-form")
    end

    test "an honest operator-only message IS rendered on the tenant plane" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = ai_mount(org_id, :tenant)

      html = render_live(AnalyticsLive, mount, [org_id])

      assert html =~ "Requires platform/operator authority"
      assert html =~ ~s(data-state="unauthorized")
      assert html =~ ~s(id="ai-analytics-result")
    end

    test "the honest state renders up front — no question submitted, never a fabricated result" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = ai_mount(org_id, :tenant)

      # load/3's default opts never run an ask (`run: false`) — the honest card
      # above is NOT gated on @result; it renders even before any submit.
      html = render_live(AnalyticsLive, mount, [org_id])

      assert html =~ "Requires platform/operator authority"
    end

    test "T144 itself is UNCHANGED — a crafted/direct 'ask' event on the tenant plane still refuses (defense-in-depth, not just a hidden button)" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = ai_mount(org_id, :tenant)

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:samen_mount, mount)
        |> Phoenix.Component.assign(:samen_acting_as, false)
        |> AnalyticsLive.load(org_id)

      {:noreply, socket} =
        AnalyticsLive.handle_event("ask", %{"question" => "what is total MRR?"}, socket)

      assert socket.assigns.result == {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  describe "operator plane — the real input still renders (T144 not weakened)" do
    test "the ask-box INPUT renders on the operator plane" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = ai_mount(org_id, :operator)

      html = render_live(AnalyticsLive, mount, [org_id])

      assert html =~ ~s(id="ai-analytics-input")
      assert html =~ ~s(id="ai-analytics-ask-form")
      refute html =~ "Requires platform/operator authority"
    end
  end

  # ---------------------------------------------------------------------------
  describe "Samen.Web.AI.Components.analytics_ask_offered?/1 — the posture predicate directly" do
    test "true for an operator-plane mount, false for a tenant-plane mount" do
      org_id = Ash.UUID.generate()

      assert Samen.Web.AI.Components.analytics_ask_offered?(ai_mount(org_id, :operator))
      refute Samen.Web.AI.Components.analytics_ask_offered?(ai_mount(org_id, :tenant))
    end
  end
end
