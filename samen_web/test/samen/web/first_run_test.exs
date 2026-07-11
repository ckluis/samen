defmodule Samen.Web.FirstRunTest do
  @moduledoc """
  A5 Task 2 — the PER-PLANE FIRST-RUN experience (WS-A design §3.1, AC-G5-2):

    * TENANT plane — a zero-data org gets the first-run checklist card on the CRM
      landing surface (`ContactsLive`): *add your first contact · load sample data ·
      invite a teammate*. Once ANY core row exists the card DISAPPEARS (the second
      half of AC-G5-2 — anti-tautology: the same render that showed the card now
      must not).
    * OPERATOR plane — n/a by design: `first_run?/2` is FALSE BY CONSTRUCTION on an
      operator mount (red path), and the operator's designed first-run surface is the
      Accounts empty state (asserted in `empty_states_sweep_test.exs`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.FirstRun

  defp render_contacts(org_id, plane_opts \\ []) do
    render_live(ContactsLive, build_mount(:crm, plane_opts), [org_id])
  end

  defp create_contact!(org_id, name) do
    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, display_name: name}, authorize?: false)
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # AC-G5-2 — appears at zero data, disappears once data exists
  # ---------------------------------------------------------------------------

  test "a zero-data tenant sees the first-run checklist (create + sample + invite steps)" do
    html = render_contacts(Ash.UUID.generate())

    assert html =~ ~s(id="first-run")
    # Step 1: the create CTA, wired to the surface's create event.
    assert html =~ ~s(id="first-run-create")
    assert html =~ ~s(phx-click="new_contact")
    assert html =~ "Add your first contact"
    # Step 2: the sample-data offer (enabled in the test env config).
    assert html =~ ~s(id="first-run-sample")
    assert html =~ ~s(phx-click="load_sample_data")
    # Step 3: the invite pointer (copy only — no fake button).
    assert html =~ "Invite a teammate"
  end

  test "the checklist DISAPPEARS once the org has data (AC-G5-2 second half)" do
    org_id = Ash.UUID.generate()
    assert render_contacts(org_id) =~ ~s(id="first-run")

    create_contact!(org_id, "First Real Contact")

    html = render_contacts(org_id)
    refute html =~ ~s(id="first-run")
    assert html =~ "First Real Contact"
  end

  test "FirstRun.first_run?/2 detects zero rows across the CRM core resources (person AND company)" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    assert FirstRun.first_run?(mount, org_id)

    # A COMPANY row alone (person still zero) already ends first-run — the checklist is
    # "no data yet", not "no contacts yet".
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "Real Co"}, authorize?: false)
    |> Ash.create!()

    refute FirstRun.first_run?(mount, org_id)
  end

  # ---------------------------------------------------------------------------
  # Red paths — the checklist can never render on the operator plane / no-org
  # ---------------------------------------------------------------------------

  test "RED PATH: the operator plane NEVER gets the tenant checklist — even over a zero-data org" do
    org_id = Ash.UUID.generate()

    # first_run?/2 is false BY CONSTRUCTION on an operator mount…
    refute FirstRun.first_run?(build_mount(:crm, plane: :operator, target_org_id: org_id), org_id)

    # …and the rendered operator page carries no first-run card (belt: writable? also gates).
    html = render_contacts(org_id, plane: :operator, target_org_id: org_id)
    refute html =~ ~s(id="first-run")
  end

  test "RED PATH: no org resolved → no first-run card (and no crash)" do
    refute FirstRun.first_run?(build_mount(:crm), nil)
    refute render_live(ContactsLive, build_mount(:crm), [nil]) =~ ~s(id="first-run")
  end
end
