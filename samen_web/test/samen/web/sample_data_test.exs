defmodule Samen.Web.SampleDataTest do
  @moduledoc """
  A5 Task 2 — the GUARDED in-app sample-data action (WS-A design §3.1, AC-G5-3 +
  RP-G5-3): `Samen.Web.SampleData.load/2` behind the empty_state `:sample` slot and
  the first-run checklist.

  Green: a zero-data tenant loads synthetic companies+contacts through the REAL Ash
  create actions; the list refreshes; the load is IDEMPOTENT and AUDITED.

  Red paths (each anti-tautology probed by the paired green path — the SAME call that
  succeeds on the tenant/dev path is refused when exactly one guard condition flips):

    * RP-G5-3a — refused on the OPERATOR plane, zero writes.
    * RP-G5-3b — refused in PROD-without-flag; the flag re-enables (discrimination).
    * MC-2     — seeded PII is NOT plaintext at rest: the raw rows carry no sample
      name/email/phone fragment (the vault write path, same as a real tenant write).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.SampleData

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsLive.load(org_id)
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ContactsLive.handle_event(name, params, socket)
    socket
  end

  defp person_rows(org_id) do
    Samen.WebTest.Crm.Person
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp company_rows(org_id) do
    Samen.WebTest.Crm.Company
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
  end

  defp audit_rows(org_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_detail FROM aud_event WHERE aud_detail LIKE 'event=sample_data_loaded%' AND aud_actor_id LIKE $1",
        ["%#{org_id}%"]
      )

    rows
  end

  # ---------------------------------------------------------------------------
  # Green — load via the REAL page event, idempotent, audited (AC-G5-3)
  # ---------------------------------------------------------------------------

  test "the empty-state offer loads sample data through the page event, refreshes the list, and audits" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    # The offer is rendered (first-run + empty state) on the zero-data tenant page.
    html = render_html(ContactsLive, socket.assigns)
    assert html =~ ~s(id="load-sample-data")
    assert html =~ ~s(phx-click="load_sample_data")

    socket = event(socket, "load_sample_data", %{})

    # Real rows landed and the BOUNDED list re-read them.
    assert length(person_rows(org_id)) == 3
    assert length(company_rows(org_id)) == 2
    assert length(socket.assigns.page.items) == 3
    # First-run is over; the sample rows render (tenant plane = names in the clear).
    refute socket.assigns.first_run
    html = render_html(ContactsLive, socket.assigns)
    assert html =~ "Aster Vale"
    refute html =~ ~s(id="first-run")

    # AUDITED: the token-only audit line landed (event + counts, no PII).
    assert [[detail]] = audit_rows(org_id)
    assert detail =~ "kind=crm companies=2 contacts=3"
    refute detail =~ "Aster"
    refute detail =~ "sample.invalid"
  end

  test "IDEMPOTENT: a second load is a no-op ({:ok, :already_loaded}, zero new writes)" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:crm)

    assert {:ok, %{companies: 2, contacts: 3}} = SampleData.load(mount, org_id)
    assert {:ok, :already_loaded} = SampleData.load(mount, org_id)

    assert length(person_rows(org_id)) == 3
    assert length(company_rows(org_id)) == 2
    # And only ONE audit line — the no-op is not re-audited as a load.
    assert length(audit_rows(org_id)) == 1
  end

  # ---------------------------------------------------------------------------
  # MC-2 — seeded PII goes through the VAULT, never a plaintext column write
  # ---------------------------------------------------------------------------

  test "RED PATH (MC-2): sample PII is NOT plaintext at rest — raw rows carry no name/email/phone fragment" do
    org_id = Ash.UUID.generate()
    assert {:ok, _} = SampleData.load(build_mount(:crm), org_id)

    # Raw records (resolver-bypassing): the vaulted composites must be tokens, not values.
    for raw <- person_rows(org_id) do
      refute inspect(raw.full_name) =~ "Vale"
      refute inspect(raw.full_name) =~ "Pike"
      refute inspect(raw.full_name) =~ "Solano"
      refute inspect(raw.emails) =~ "sample.invalid"
      refute inspect(raw.phones) =~ "555 010"
    end

    # Belt: a raw SQL scan of the ENTIRE physical person table — no sample plaintext in
    # ANY column. If the seed had written a plaintext PII column, this scan FAILS.
    %{rows: rows} = Samen.WebTest.Repo.query!("SELECT t.* FROM swp_person t WHERE t.swp_org_id = $1", [Ecto.UUID.dump!(org_id)])
    blob = inspect(rows)
    refute blob =~ "aster.vale@sample.invalid"
    refute blob =~ "+1 555 0101"
    refute blob =~ ~s("last":"Vale")

    # …and the SAME data resolves CLEAR through PiiResolution on the tenant page
    # (anti-tautology for the scans above: the plaintext EXISTS, but only through the
    # resolver — so the raw scans are scanning real data, not an empty write).
    socket = mount_socket(org_id)
    assert render_html(ContactsLive, socket.assigns) =~ "aster.vale@sample.invalid"
  end

  test "RED PATH: on the operator plane the SAME data renders masked — sample data respects the plane" do
    org_id = Ash.UUID.generate()
    assert {:ok, _} = SampleData.load(build_mount(:crm), org_id)

    html = render_html(ContactsLive, mount_socket(org_id, plane: :operator, target_org_id: org_id).assigns)
    assert html =~ "••••"
    refute html =~ "aster.vale@sample.invalid"
    refute html =~ "Aster Vale"
  end

  # ---------------------------------------------------------------------------
  # RP-G5-3a — operator plane refused (zero writes)
  # ---------------------------------------------------------------------------

  test "RED PATH (RP-G5-3a): the operator plane is REFUSED before any write — and the page surfaces it" do
    org_id = Ash.UUID.generate()
    op_mount = build_mount(:crm, plane: :operator, target_org_id: org_id)

    assert {:error, :operator_plane} = SampleData.load(op_mount, org_id)
    assert person_rows(org_id) == []
    assert company_rows(org_id) == []

    # Driving the HANDLER directly on an operator socket (the affordance is absent from
    # the DOM, but enforcement is the action's guard, not the hidden button).
    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)
    socket = event(socket, "load_sample_data", %{})
    assert socket.assigns.sample_error
    assert person_rows(org_id) == []

    # The offer affordance is also not rendered on the operator plane (belt).
    refute render_html(ContactsLive, socket.assigns) =~ ~s(id="load-sample-data")
  end

  test "SampleData.offer?/1 is false on the operator plane and for kinds without samples" do
    assert SampleData.offer?(build_mount(:crm))
    refute SampleData.offer?(build_mount(:crm, plane: :operator, target_org_id: Ash.UUID.generate()))
    refute SampleData.offer?(build_mount(:billing))
  end

  # ---------------------------------------------------------------------------
  # RP-G5-3b — disabled in prod unless the flag is set (fail-closed config gate)
  # ---------------------------------------------------------------------------

  test "RED PATH (RP-G5-3b): prod-without-flag is REFUSED; the explicit flag re-enables (discrimination)" do
    org_id = Ash.UUID.generate()
    mount = build_mount(:crm)
    original = Application.get_env(:samen_web, SampleData)
    on_exit(fn -> Application.put_env(:samen_web, SampleData, original) end)

    # prod + no flag → refused, zero writes.
    Application.put_env(:samen_web, SampleData, env: :prod)
    refute SampleData.enabled?()
    refute SampleData.offer?(mount)
    assert {:error, :disabled} = SampleData.load(mount, org_id)
    assert person_rows(org_id) == []

    # UNCONFIGURED host → fail-closed (env defaults :prod, enabled defaults false).
    Application.delete_env(:samen_web, SampleData)
    refute SampleData.enabled?()
    assert {:error, :disabled} = SampleData.load(mount, org_id)

    # prod + explicit flag → the SAME call succeeds (the refusal discriminates on the
    # flag, not on some always-broken path).
    Application.put_env(:samen_web, SampleData, env: :prod, enabled: true)
    assert SampleData.enabled?()
    assert {:ok, %{contacts: 3}} = SampleData.load(mount, org_id)
  end

  test "RED PATH: a kind without sample data is refused, no writes" do
    org_id = Ash.UUID.generate()
    assert {:error, {:no_sample_data, :billing}} = SampleData.load(build_mount(:billing), org_id)
    assert {:error, :no_org} = SampleData.load(build_mount(:crm), nil)
  end
end
