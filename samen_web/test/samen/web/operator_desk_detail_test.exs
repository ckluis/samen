defmodule Samen.Web.OperatorDeskDetailTest do
  @moduledoc """
  T149 B1/B2a — the operator Desk TICKET DETAIL surface (`/operator/desk/:id`): open a ticket,
  read its conversation, and ANSWER it (the resolve affordance DeskLive lacked). Plus B2a: the
  "Draft AI reply" button surfaces the EXISTING `Samen.AI.SupportOperator.draft_reply/3`
  fail-honestly (never a faked draft).

  Proofs (each red pairs with a positive control — anti-tautology):

    * RENDER — the detail renders the ticket, its requester (tenant-admin, CLEAR), and the
      seeded conversation message body CLEAR on the operator's own tenant plane.
    * REPLY — posting a reply creates a `Support.Message` through the governed create; the new
      body then renders in the thread.
    * MASKING (green/red) — GREEN: the message body is CLEAR on the operator's own tenant plane
      (the SaaS owns its desk). RED: on an operator-PLANE (impersonation) mount the SAME body
      renders `••••`, never plaintext.
    * DRAFT-AI (fail-honest) — the "Draft AI reply" button is present; invoking it never crashes
      and, on a host that has not adopted the AI-plane draft persistence, surfaces the honest
      not-configured state rather than a faked draft.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.DeskDetailLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  @reply_body "Operator reply: rolling out the fix now, thanks for your patience."

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    ticket = hd(hd(seed.accounts).tickets)
    %{seed: seed, ticket_id: ticket.id, subject: ticket.subject}
  end

  defp tenant_socket(seed) do
    mount = build_operator_mount(seed.operator_org_id)
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :samen_mount, mount)
  end

  # An operator-PLANE (impersonation) mount over the operator namespace — the odd hand-crafted
  # mount that must fail MASKED (Samen.Web.Operator.scope/1 A3 plane-awareness).
  defp operator_plane_socket(seed) do
    mount =
      Samen.Web.Mount.new(:operator, Op, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.operator("op-1", seed.operator_org_id, "s"),
        labels: %{operator_org_id: seed.operator_org_id}
      )

    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :samen_mount, mount)
  end

  test "renders the ticket + requester (CLEAR) + seeded conversation body (CLEAR, own plane)", %{seed: seed, ticket_id: id, subject: subject} do
    html = render_live(DeskDetailLive, build_operator_mount(seed.operator_org_id), [id])

    assert html =~ "operator-desk-detail"
    assert html =~ subject
    # Requester tenant-admin PII CLEAR (the SaaS's own customer).
    assert html =~ OpSeeds.admin_full_name()
    # The seeded agent reply body renders CLEAR on the operator's own tenant plane.
    assert html =~ "Thanks for reaching out"
    refute html =~ "••••"
    # The resolve affordances exist.
    assert html =~ ~s(id="reply-form")
    assert html =~ ~s(id="draft-ai-reply")
  end

  test "not-found ticket renders the not-found card (never a crash)", %{seed: seed} do
    html = render_live(DeskDetailLive, build_operator_mount(seed.operator_org_id), [Ash.UUID.generate()])
    assert html =~ "ticket-not-found"
  end

  test "REPLY: posting a reply creates a Support.Message and the new body renders in the thread", %{seed: seed, ticket_id: id} do
    socket = DeskDetailLive.load(tenant_socket(seed), id)

    {:noreply, socket} =
      DeskDetailLive.handle_event("reply", %{"reply" => %{"body" => @reply_body}}, socket)

    assert socket.assigns.reply_error == nil

    # A real Support.Message row now carries the reply (body vault-routed).
    %{rows: [[count]]} = Samen.WebTest.Repo.query!("SELECT count(*) FROM wqm_message")
    assert count >= 1

    # And the reply renders CLEAR in the reloaded thread.
    html = render_html(DeskDetailLive, socket.assigns)
    assert html =~ @reply_body
  end

  test "REPLY: a blank body is refused (reason-required, no write)", %{seed: seed, ticket_id: id} do
    socket = DeskDetailLive.load(tenant_socket(seed), id)
    {:noreply, socket} = DeskDetailLive.handle_event("reply", %{"reply" => %{"body" => "   "}}, socket)
    assert socket.assigns.reply_error =~ "required"
  end

  test "MASKING red: on an operator-PLANE mount the SAME message body renders ••••, never plaintext", %{seed: seed, ticket_id: id} do
    html = render_html(DeskDetailLive, DeskDetailLive.load(operator_plane_socket(seed), id).assigns)

    assert html =~ "••••"
    refute html =~ "Thanks for reaching out"
  end

  test "DRAFT-AI (fail-honest): the button invocation never crashes and never fakes a draft", %{seed: seed, ticket_id: id} do
    socket = DeskDetailLive.load(tenant_socket(seed), id)
    {:noreply, socket} = DeskDetailLive.handle_event("draft_ai", %{}, socket)

    # Either a real draft (a host with the AI-plane draft persistence wired) OR the honest
    # not-configured state — NEVER a crash, NEVER a faked draft with no backing.
    assert socket.assigns.ai_draft != nil or socket.assigns.ai_error != nil

    if socket.assigns.ai_error do
      assert socket.assigns.ai_error =~ "No draft was produced"
      html = render_html(DeskDetailLive, socket.assigns)
      assert html =~ ~s(id="ai-error")
    end
  end

  # PP-15 — a keyless/deterministic (SIMULATED) operator support draft ALWAYS renders the loud
  # "SIMULATED — not a real model" badge (the honesty provenance `draft_reply/3` now preserves
  # and this surface carries into the render). Anti-tautology twin below.
  test "DRAFT-AI SIMULATED (PP-15): a simulated draft renders the loud SIMULATED badge", %{seed: seed, ticket_id: id} do
    socket =
      DeskDetailLive.load(tenant_socket(seed), id)
      |> Phoenix.Component.assign(
        ai_draft: %{text: "fake-completion:deadbeefdeadbeef", approval_id: "ap-1", simulated: true},
        ai_error: nil
      )

    html = render_html(DeskDetailLive, socket.assigns)

    assert html =~ "SIMULATED — not a real model"
    assert html =~ ~s(data-simulated="true")
  end

  test "DRAFT-AI SIMULATED positive control (PP-15): a non-simulated draft shows NO SIMULATED badge", %{seed: seed, ticket_id: id} do
    socket =
      DeskDetailLive.load(tenant_socket(seed), id)
      |> Phoenix.Component.assign(
        ai_draft: %{text: "A real-model reply.", approval_id: "ap-2", simulated: false},
        ai_error: nil
      )

    html = render_html(DeskDetailLive, socket.assigns)

    # The draft still renders — only the SIMULATED badge is absent (badge is flag-driven).
    assert html =~ ~s(id="ai-draft")
    refute html =~ "SIMULATED"
    assert html =~ ~s(data-simulated="false")
  end
end
