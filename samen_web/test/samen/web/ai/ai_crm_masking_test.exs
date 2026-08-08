defmodule Samen.Web.AI.CrmMaskingTest do
  @moduledoc """
  T155 — the INV-7 masking proof on the AI CRM grounding surface (`Samen.Web.AI.CrmLive`).
  The record the AI grounds on is rendered on the caller's plane; a vault-routed 🔒 field
  (`full_name`, `emails`) must render CLEAR on the tenant plane and `••••` on the operator
  plane — never plaintext, never a `vt_*` token. The three-proof discipline (CLAUDE.md):
  green (tenant clear), red (operator masked), sabotage twin (the plane flip is the gate —
  both directions asserted here; the refutability patch is `scripts/sabotages/143-*`).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Web.Mount
  alias Samen.WebTest.Seeds

  setup do
    %{org_id: org_id, crm: crm} = Seeds.seed_all()
    %{org_id: org_id, person: crm.person}
  end

  defp ai_mount(_org_id, :tenant),
    do:
      Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{ai_crm_resource: Samen.WebTest.Crm.Person}
      )

  defp ai_mount(org_id, :operator),
    do:
      Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.operator("op-1", org_id, "test-session"),
        labels: %{ai_crm_resource: Samen.WebTest.Crm.Person}
      )

  test "GREEN — tenant plane grounds on the record's PII in the CLEAR", %{org_id: org_id, person: person} do
    html =
      render_live(Samen.Web.AI.CrmLive, ai_mount(org_id, :tenant), [org_id, [id: person.id]])

    assert html =~ "ai-crm-preview"
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
    refute html =~ "vt_"
  end

  test "RED — operator plane grounds MASKED (••••), no plaintext, no vt_ token", %{org_id: org_id, person: person} do
    html =
      render_live(Samen.Web.AI.CrmLive, ai_mount(org_id, :operator), [org_id, [id: person.id]])

    assert html =~ "••••"
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ "vt_"

    # The MaskingCase DOM assertion — the plaintexts are masked in the rendered DOM.
    assert_masked_dom!(html, [Seeds.contact_full_name(), Seeds.contact_email()])
  end

  test "SABOTAGE TWIN — the plane is the gate (anti-tautology): same record, opposite planes", %{
    org_id: org_id,
    person: person
  } do
    tenant_html =
      render_live(Samen.Web.AI.CrmLive, ai_mount(org_id, :tenant), [org_id, [id: person.id]])

    operator_html =
      render_live(Samen.Web.AI.CrmLive, ai_mount(org_id, :operator), [org_id, [id: person.id]])

    # The ONLY difference is the plane: tenant reveals, operator masks.
    assert tenant_html =~ Seeds.contact_full_name()
    refute operator_html =~ Seeds.contact_full_name()
    assert operator_html =~ "••••"

    # A modeled leak IS detected by the same scan (the assertion is refutable).
    assert_leak_detected!(tenant_html <> Seeds.contact_full_name(), Seeds.contact_full_name())
  end
end
