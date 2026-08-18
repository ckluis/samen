defmodule PawChart.ClinicMaskingTest do
  @moduledoc """
  PP-4 (Batch 5b CLINIC-SURFACE) — the per-plane masking proof for the Clinic tenant
  surface. This surface RENDERS vault-routed 🔒 fields — `Patient.full_name`/`emails`/
  `phones` (CorePerson) and `Pet.microchip` (`pii_pet_microchip`) — so it ships the THREE
  `Samen.MaskingCase` proofs (masking watch-list discipline):

    1. GREEN — the TENANT plane (clinic staff over their OWN org) resolves the fields CLEAR.
    2. RED — the OPERATOR-without-grant plane resolves them `%Samen.Masked{}` (••••), and
       the rendered DOM shows `••••`, NEVER the plaintext, NEVER a `vt_*` token.
    3. SABOTAGE twin (anti-tautology) — the DOM mask scan is REFUTABLE: the SAME scan run
       against the CLEAR (tenant-plane) render DOES detect the plaintext, so the RED
       assertion is non-vacuous.

  All reads resolve through `Samen.Api.PiiResolution` on the actor's plane via
  `PawChartWeb.ClinicReads` — the surface's single read path. Sabotage patch 182 (forcing
  the resolver to the tenant plane regardless of actor) makes the operator plane leak and
  flips the RED test below.
  """
  use PawChart.DataCase, async: false
  use Samen.MaskingCase

  alias PawChartWeb.ClinicLive
  alias PawChartWeb.ClinicReads, as: Reads

  @org "c1112d00-0000-4000-8000-00000000d001"
  @first "Olivia"
  @last "Ownerton"
  @email "olivia.ownerton@example.test"
  @phone "+15550009999"
  @microchip "985-CLINIC-CHIP-LEAK-0001"

  setup do
    {:ok, owner} =
      Reads.create_owner(@org, %{"first" => @first, "last" => @last, "email" => @email, "phone" => @phone})

    {:ok, _pet} =
      Reads.create_pet(@org, %{"name" => "Biscuit", "species" => "canine", "microchip" => @microchip, "owner_id" => owner.id})

    :ok
  end

  defp tenant_scope, do: Reads.tenant_scope(@org)

  # The operator-without-grant impersonation scope (plane: :operator + impersonation
  # marker, NO reveal grant) — the exact shape `Samen.Web.Plane.operator/3` mints.
  defp operator_scope,
    do: %Samen.Scope{actor: %{id: "op-clinic", org_id: @org, role: :member, plane: :operator, impersonation: %{session_id: "sess-1"}}}

  # Render the surface through its real load/1 + render/1 on a given plane (no Endpoint).
  defp render_on(plane) do
    mount =
      case plane do
        :tenant -> Samen.Web.Mount.new(:crm, PawChart.Crm, PawChart.Repo, plane: Samen.Web.Plane.tenant())
        :operator -> Samen.Web.Mount.new(:crm, PawChart.Crm, PawChart.Repo, plane: Samen.Web.Plane.operator("op-1", @org, "sess-1"))
      end

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, plane == :operator)
      |> ClinicLive.load(@org, %{})

    socket.assigns
    |> Map.put(:__changed__, %{})
    |> ClinicLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ==========================================================================
  # 1. GREEN — the TENANT plane resolves the clinic's own PII CLEAR
  # ==========================================================================

  test "GREEN: the tenant plane reads the owner's name/email/phone + the pet microchip CLEAR" do
    [owner] = Reads.owner_roster(tenant_scope())
    [pet] = Reads.pet_roster(tenant_scope())

    # full_name resolves to a clear struct/JSON string carrying the name (never Masked).
    refute match?(%Samen.Masked{}, owner.full_name)
    assert inspect(owner.full_name) =~ @first

    # emails/phones resolve CLEAR — the surface's render helpers surface the plaintext.
    assert ClinicLive.owner_email(owner) == @email
    assert ClinicLive.owner_phone(owner) == @phone

    # microchip resolves to the exact plaintext.
    assert_plane_clear!(pet.microchip, @microchip)
  end

  # ==========================================================================
  # 2. RED — the OPERATOR-without-grant plane masks everything (value + DOM)
  # ==========================================================================

  test "RED: the operator-without-grant plane resolves owner PII + microchip to %Masked{} (••••)" do
    [owner] = Reads.owner_roster(operator_scope())
    [pet] = Reads.pet_roster(operator_scope())

    assert_plane_masked!(owner.full_name)
    assert_plane_masked!(pet.microchip, @microchip)

    # emails/phones are masked (••••) via the SAME render helper, never the plaintext.
    assert to_string(ClinicLive.owner_email(owner)) == mask()
    refute inspect(owner.emails) =~ @email
    refute inspect(owner.phones) =~ @phone
  end

  test "RED (DOM): the operator-plane render shows •••• and NEVER the plaintext or a vt_ token" do
    html = render_on(:operator)

    assert_masked_dom!(html, [@first, @last, @email, @phone, @microchip])
  end

  # ==========================================================================
  # 3. SABOTAGE twin (anti-tautology) — the DOM mask scan is REFUTABLE
  # ==========================================================================

  test "SABOTAGE twin: the SAME scan DOES catch the plaintext in the CLEAR (tenant) render — the RED assertion is non-vacuous" do
    clear_html = render_on(:tenant)

    # The tenant render is the "leak" scenario (clear PII in the DOM): the scan that the
    # masked render passes MUST detect the plaintext here, proving RED is refutable.
    assert_leak_detected!(clear_html, @microchip)
    assert_leak_detected!(clear_html, @first)
  end
end
