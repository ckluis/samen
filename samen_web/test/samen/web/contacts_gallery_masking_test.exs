defmodule Samen.Web.ContactsGalleryMaskingTest do
  @moduledoc """
  T54 (G5) — per-plane masking on the CRM Contacts GALLERY (`Samen.Web.CRM.ContactsGalleryLive`,
  the first client of `Samen.UI.gallery/1`). Contact cards render VAULT-ROUTED (🔒) PII
  (`full_name`/`emails`), so this surface ships the sanctioned three-part `Samen.MaskingCase`
  proof (CLAUDE.md's masking watch-list discipline), the SAME green/red/sabotage shape as the
  file-preview / CSV masking tests:

    * GREEN — the tenant plane (the org's own console) renders the vaulted name/email in the CLEAR.
    * RED — the operator (impersonation) plane renders `••••` for the SAME cards: never the
      plaintext, never a `vt_*` vault token (whole-DOM scan).
    * SABOTAGE twins — (1) plane flip: the ONLY difference between GREEN and RED is the mount's
      plane (the resolver is the gate, not a blanket mask); (2) leak-scan refutability: a modeled
      raw (unmasked) card render IS caught by the same scan, so the RED assertion is not vacuous.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Factory
  alias Samen.Web.CRM.ContactsGalleryLive
  alias Samen.WebTest.Crm.Person

  @secret_first "GalleryVaultedFirst"
  @secret_last "Gallery-Secret-Last"
  @secret_email "gallery-secret@vault.example"

  defp seed_secret_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last, email: @secret_email), %{
        display_name: "Public Gallery Display",
        org_id: org_id
      }),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  defp render_gallery(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> ContactsGalleryLive.load(org_id)
    |> then(&render_html(ContactsGalleryLive, &1.assigns))
  end

  test "GREEN: the tenant plane renders the vaulted name + email in the CLEAR" do
    org_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    html = render_gallery(build_mount(:crm), org_id)

    assert html =~ @secret_first
    assert html =~ @secret_last
    assert html =~ @secret_email
    refute html =~ "vt_"
    # The non-PII display name rides along on every plane.
    assert html =~ "Public Gallery Display"
  end

  test "RED: the operator plane renders •••• — NEVER plaintext, NEVER a vt_ token" do
    org_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    html = render_gallery(build_mount(:crm, plane: :operator, target_org_id: org_id), org_id)

    # Whole-DOM scan: mask present, every plaintext half ABSENT, no vault token anywhere.
    assert_masked_dom!(html, [@secret_first, @secret_last, @secret_email])
    # The non-PII display name is untouched — masking is per-field, not per-page.
    assert html =~ "Public Gallery Display"
  end

  test "SABOTAGE (plane flip): the SAME contact goes clear on tenant, masked on operator" do
    org_id = Ash.UUID.generate()
    person = seed_secret_person!(org_id)

    # The card value resolved through the SAME seam the LiveView renders through, both planes.
    at_rest =
      Person
      |> Ash.Query.filter(id == ^person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)

    tenant_name = resolve_on_plane(at_rest, Person, :tenant, repo: Samen.WebTest.Repo).full_name
    operator_name = resolve_on_plane(at_rest, Person, :operator, repo: Samen.WebTest.Repo).full_name

    # The only difference is the plane → the resolver is the gate (not a serialize-as-•••• blanket).
    assert_plane_masked!(operator_name)
    refute match?(%Samen.Masked{}, tenant_name)
  end

  test "SABOTAGE (leak-scan refutability): a modeled UNMASKED card render IS caught by the scan" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    # A raw (unmasked) card — the mistake INV-1 forbids: the plaintext straight in the DOM. If the
    # gallery's mask scan could not detect this, the RED proof above would be vacuous.
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
