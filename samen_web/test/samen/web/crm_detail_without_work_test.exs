defmodule Samen.Web.CRMDetailWithoutWorkTest do
  @moduledoc """
  The contact and company detail pages write a logged activity as a Work task. On a host that
  does not mount the Work scope there is no task resource, so the page builds no composer form,
  renders without it, and a composer event is answered with a flash, never a crash. A host with
  the Work scope keeps the composer (positive control).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.{CompanyLive, ContactLive}

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, contact_id: seeded.crm.person.id, company_id: seeded.crm.company.id}
  end

  defp base(live, org_id, id) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, []))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> live.load(org_id, id)
  end

  # The same page, re-evaluated against a mount whose host root mounts no Work scope.
  defp without_work(live, socket) do
    mount = socket.assigns.samen_mount
    no_work = Phoenix.Component.assign(socket, :samen_mount, %{mount | namespace: Samen.NoWorkHost.Crm})
    live.actor_changed(no_work)
  end

  defp tab(assigns), do: Map.put(assigns, :active_tab, "activity")

  defp assert_renders_without_composer(live, ctx, key) do
    with_work = base(live, ctx.org_id, ctx[key])
    assert with_work.assigns.activity_form
    assert render_html(live, tab(with_work.assigns)) =~ ~s(id="log-activity-form")

    socket = without_work(live, with_work)
    assert socket.assigns.activity_form == nil
    html = render_html(live, tab(socket.assigns))
    refute html =~ ~s(id="log-activity-form")
    assert html =~ ~s(id="crm-)
  end

  defp assert_composer_event_answered(live, ctx, key) do
    socket = without_work(live, base(live, ctx.org_id, ctx[key]))

    for event <- ["validate_activity", "log_activity"] do
      assert {:noreply, socket} = live.handle_event(event, %{"activity" => %{"title" => "x"}}, socket)
      assert socket.assigns.flash["error"] =~ "Work scope"
    end
  end

  test "the contact page without the Work scope renders with no composer form", ctx,
    do: assert_renders_without_composer(ContactLive, ctx, :contact_id)

  test "the company page without the Work scope renders with no composer form", ctx,
    do: assert_renders_without_composer(CompanyLive, ctx, :company_id)

  test "a composer event on the contact page with no composer is answered, not a crash", ctx,
    do: assert_composer_event_answered(ContactLive, ctx, :contact_id)

  test "a composer event on the company page with no composer is answered, not a crash", ctx,
    do: assert_composer_event_answered(CompanyLive, ctx, :company_id)
end
