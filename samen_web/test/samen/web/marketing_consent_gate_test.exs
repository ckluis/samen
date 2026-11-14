defmodule Samen.Web.MarketingConsentGateTest do
  @moduledoc """
  The send gate (`Marketing.Reads.enqueue_send/3` → `refuse_if_undeliverable/3`) derives consent from the append-only
  ledger. A ledger that cannot be READ is not "no withdrawal on file": the send is refused (fail closed) with the same
  outage copy as a failed deliverability check, never let through and never mislabelled "consent withdrawn".

  The outage is real: the ledger table is renamed inside the sandbox transaction. The positive control is the SAME
  call with the ledger readable.
  """
  use Samen.WebTest.DataCase, async: false

  import ExUnit.CaptureLog

  alias Samen.Web.Marketing.Reads, as: MktReads
  alias Samen.Web.Mount

  defp send_attrs(org_id, mkt) do
    %{
      subscriber_id: mkt.active_subscriber.id,
      org_id: org_id,
      campaign_id: mkt.campaign.id,
      template_id: mkt.template.id
    }
  end

  test "RED: an unreadable consent ledger refuses the send (:deliverability_check_failed); healed, the same call sends" do
    %{org_id: org_id, marketing: mkt} = Seeds.seed_all()
    mount = build_mount(:marketing)
    scope = Mount.scope(mount, org_id)

    table = AshPostgres.DataLayer.Info.table(Mount.resource(mount, ConsentEvent))
    Repo.query!(~s(ALTER TABLE "#{table}" RENAME TO "#{table}_outage"))

    log =
      capture_log(fn ->
        assert {:error, :deliverability_check_failed} = MktReads.enqueue_send(mount, scope, send_attrs(org_id, mkt))
      end)

    assert log =~ "read=marketing_consent_state"

    # POSITIVE CONTROL: the ledger is back; the same call is accepted
    Repo.query!(~s(ALTER TABLE "#{table}_outage" RENAME TO "#{table}"))
    assert {:ok, _send} = MktReads.enqueue_send(mount, scope, send_attrs(org_id, mkt))
  end
end
