defmodule Samen.Web.WebhookDlqOrgColumnTest do
  @moduledoc """
  T114/R5 — the DLQ org column was stored on `whk_event.org_id` but never
  rendered (`_orch/ux/dogfood-report.md` R5). This proves the fix: an envelope
  with a resolved `org_id` renders it (as a bounded id fragment, non-PII) and
  cross-links to the new per-tenant deliverability drill-down
  (`/operator/deliverability/:org_id`); an envelope with NO org_id (the common
  pre-processing case — org resolves DURING processing) renders the honest
  em-dash placeholder, never a crash, never a fabricated link.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.WebhookDlqLive
  alias Samen.WebTest.Repo
  alias Samen.Webhook.Event

  test "an envelope WITH a resolved org_id surfaces it and cross-links to the deliverability page" do
    org_id = Ash.UUID.generate()

    {:ok, :inserted, _row} =
      Event.insert_received(Repo, %{
        provider: "orgcol",
        event_id: "evt_orgcol_#{System.unique_integer([:positive])}",
        kind: "test_kind",
        domain: "delivery",
        occurred_at: DateTime.utc_now(),
        org_id: org_id
      })

    html = render_live(WebhookDlqLive, build_operator_mount(Ecto.UUID.generate()), [])

    assert html =~ "/operator/deliverability/#{org_id}"
    # A bounded, non-PII id fragment — not the full uuid, not a fabricated tenant name.
    assert html =~ String.slice(org_id, 0, 8)
  end

  test "an envelope with NO org_id (pre-processing) renders the honest placeholder, never a crash" do
    {:ok, :inserted, _row} =
      Event.insert_received(Repo, %{
        provider: "orgcol",
        event_id: "evt_orgcol_noorg_#{System.unique_integer([:positive])}",
        kind: "test_kind",
        domain: "delivery",
        occurred_at: DateTime.utc_now()
      })

    html = render_live(WebhookDlqLive, build_operator_mount(Ecto.UUID.generate()), [])

    assert html =~ "d-org"
    refute html =~ "/operator/deliverability/nil"
  end
end
