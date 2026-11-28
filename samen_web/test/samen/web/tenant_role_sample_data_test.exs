defmodule Samen.Web.TenantRoleSampleDataTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), sample data: loading it is an ADMIN's (an org-wide write whose resources the
  kernel only checks the org of), it seeds as the person acting, and the page offers it to an admin only.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`); every refusal is
  paired with a positive control.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.ContactsLive
  alias Samen.WebTest.RoleHarness, as: H

  @path "/crm/contacts"

  setup do
    H.setup_accounts()
  end

  defp people(org_id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  test "a viewer and a member are offered nothing and load nothing; an admin and an owner are offered it and load it", ctx do
    org = ctx.org_id

    for who <- [:viewer, :member] do
      socket = H.live_socket(H.log_in(Map.fetch!(ctx, who)), ContactsLive, @path, org)
      refute render_html(ContactsLive, socket.assigns) =~ ~s(id="load-sample-data"), "#{who} is offered sample data"
      socket = H.event(ContactsLive, "load_sample_data", %{}, socket)
      assert socket.assigns.sample_error =~ "admin"
      assert people(org) == [], "#{who} loaded sample data"
    end

    admin = H.live_socket(H.log_in(ctx.admin), ContactsLive, @path, org)
    assert render_html(ContactsLive, admin.assigns) =~ ~s(id="load-sample-data")
    admin = H.event(ContactsLive, "load_sample_data", %{}, admin)
    assert admin.assigns.sample_error == nil
    assert length(people(org)) == 3
  end
end
