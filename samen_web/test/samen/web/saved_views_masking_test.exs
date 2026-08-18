defmodule Samen.Web.SavedViewsMaskingTest do
  @moduledoc """
  G10 (T58) — MASKING PRESERVED ON RESTORE. A saved view stores QUERY STATE, not records;
  restoring it drives a NORMAL org-scoped, plane-masked read through the existing WS-G view
  components, so the usual per-plane masking still applies — a saved view is never a masking
  bypass. Same three-part `Samen.MaskingCase` discipline as the contacts-gallery masking test:

    * GREEN — a restored GALLERY view (view_type came from the saved view) renders the vaulted
      `full_name`/`emails` CLEAR on the tenant plane.
    * RED — the SAME restored view renders `••••` on the operator plane: never the plaintext,
      never a `vt_*` token (whole-DOM scan).
    * SABOTAGE twins — (1) plane flip: the vaulted COLUMN the saved view surfaces resolves clear
      on tenant, masked on operator (the resolver is the gate, not the saved view); (2) the mask
      scan is refutable.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Factory
  alias Samen.Web.CRM.ContactsGalleryLive
  alias Samen.Web.SavedViews
  alias Samen.Web.SavedViews.Whitelist
  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Views.SavedView

  @surface "crm.person"
  @secret_first "SavedViewVaultedFirst"
  @secret_last "SavedView-Secret-Last"
  @secret_email "savedview-secret@vault.example"

  defp whitelist do
    Whitelist.new(Person,
      sortable: [:display_name],
      filter_fields: [:display_name],
      columns: [:display_name, :full_name, :emails]
    )
  end

  defp seed_secret_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last, email: @secret_email), %{
        display_name: "Public SavedView Display",
        org_id: org_id
      }),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  # Persist a gallery saved view whose columns SURFACE the vaulted fields, then restore it —
  # returning the restored {view_type, state, view_params} the render would use.
  defp save_and_restore_gallery(org_id, user_id) do
    {:ok, sv} =
      SavedViews.save(
        SavedView,
        org_id,
        user_id,
        %{
          name: "Contacts gallery",
          surface: @surface,
          view_type: :gallery,
          view_params: %{columns: [:display_name, :full_name, :emails]}
        },
        whitelist()
      )

    {:ok, loaded} = SavedViews.get(SavedView, org_id, user_id, sv.id)
    SavedViews.apply(loaded, whitelist())
  end

  defp render_gallery(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsGalleryLive.load(org_id)
    |> then(&render_html(ContactsGalleryLive, &1.assigns))
  end

  test "GREEN: a restored gallery view renders the vaulted fields CLEAR on the tenant plane" do
    org_id = Ash.UUID.generate()
    user_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    # The saved view drives the view TYPE (gallery) and surfaces the vaulted columns.
    {view_type, _state, view_params} = save_and_restore_gallery(org_id, user_id)
    assert view_type == :gallery
    assert :full_name in view_params.columns

    html = render_gallery(build_mount(:crm), org_id)

    assert html =~ @secret_first
    assert html =~ @secret_last
    assert html =~ @secret_email
    refute html =~ "vt_"
    assert html =~ "Public SavedView Display"
  end

  test "RED: the SAME restored view renders •••• on the operator plane (no plaintext, no vt_)" do
    org_id = Ash.UUID.generate()
    user_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    {view_type, _state, _vp} = save_and_restore_gallery(org_id, user_id)
    assert view_type == :gallery

    html = render_gallery(build_mount(:crm, plane: :operator, target_org_id: org_id), org_id)

    assert_masked_dom!(html, [@secret_first, @secret_last, @secret_email])
    assert html =~ "Public SavedView Display"
  end

  test "SABOTAGE (plane flip): the vaulted COLUMN the saved view surfaces goes clear on tenant, masked on operator" do
    org_id = Ash.UUID.generate()
    user_id = Ash.UUID.generate()
    person = seed_secret_person!(org_id)

    {_vt, _state, view_params} = save_and_restore_gallery(org_id, user_id)
    # The saved view surfaces full_name as a column — masking must still gate it per plane.
    assert :full_name in view_params.columns

    at_rest =
      Person
      |> Ash.Query.filter(id == ^person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)

    tenant_name = resolve_on_plane(at_rest, Person, :tenant, repo: Samen.WebTest.Repo).full_name
    operator_name = resolve_on_plane(at_rest, Person, :operator, repo: Samen.WebTest.Repo).full_name

    assert_plane_masked!(operator_name)
    refute match?(%Samen.Masked{}, tenant_name)
  end

  test "SABOTAGE (leak-scan refutability): a modeled UNMASKED render IS caught by the scan" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    leaked_page = %Samen.Web.Page{
      items: [%{id: "leak", secret: @secret_first}],
      page_size: 12
    }

    slot = [%{inner_block: fn _c, item -> item.secret end}]

    leaked_html =
      render_component(&Samen.UI.gallery/1, %{id: "g", page: leaked_page, card: slot})

    assert_leak_detected!(leaked_html, @secret_first)
  end
end
