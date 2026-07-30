defmodule Samen.Delivery.OrgReadsTest do
  @moduledoc """
  T114 (R2) — the operator per-tenant reads over the T28/T30 delivery/suppression
  store: `Samen.Delivery.EmailEvent.list_for_org/3` and
  `Samen.Delivery.Suppression.list_for_org/3`. These back the operator
  "why didn't this tenant get their email" surface: a delivery TIMELINE (every
  event for an org, most-recent first) and the current SUPPRESSION list (every
  suppressed subscriber for an org). Both are org-BOUNDED (a sibling org's rows
  never appear) and read-count-BOUNDED (`:limit`).
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.{EmailEvent, Suppression}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp record_event(org_id, subscriber_id, kind, suffix) do
    {:ok, :inserted, row} =
      EmailEvent.record(TestRepo, %{
        provider: "orgreads",
        provider_event_id: "evt_#{suffix}_#{System.unique_integer([:positive])}",
        provider_message_id: "msg_#{suffix}",
        kind: kind,
        send_id: Ash.UUID.generate(),
        org_id: org_id,
        subscriber_id: subscriber_id,
        occurred_at: DateTime.utc_now()
      })

    row
  end

  describe "EmailEvent.list_for_org/3" do
    test "returns every event for the org, most-recent first" do
      org_id = Ash.UUID.generate()
      sub_a = Ash.UUID.generate()
      sub_b = Ash.UUID.generate()

      e1 = record_event(org_id, sub_a, "delivered", "1")
      e2 = record_event(org_id, sub_b, "bounce", "2")
      e3 = record_event(org_id, sub_a, "complaint", "3")

      events = EmailEvent.list_for_org(TestRepo, org_id)

      assert Enum.map(events, & &1.id) == [e3.id, e2.id, e1.id]
    end

    test "RED: a sibling org's events never appear (org-bounded, no cross-tenant leak)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      _mine = record_event(org_a, Ash.UUID.generate(), "delivered", "mine")
      theirs = record_event(org_b, Ash.UUID.generate(), "delivered", "theirs")

      events = EmailEvent.list_for_org(TestRepo, org_a)

      refute Enum.any?(events, &(&1.id == theirs.id))
    end

    test "an org with no events reads an empty (never crashing) list" do
      assert EmailEvent.list_for_org(TestRepo, Ash.UUID.generate()) == []
    end

    test "read-bounded: :limit caps the returned row count" do
      org_id = Ash.UUID.generate()
      for i <- 1..5, do: record_event(org_id, Ash.UUID.generate(), "delivered", "lim#{i}")

      assert length(EmailEvent.list_for_org(TestRepo, org_id, limit: 2)) == 2
    end
  end

  describe "Suppression.list_for_org/3" do
    test "returns every suppression for the org, most-recently-suppressed first" do
      org_id = Ash.UUID.generate()

      {:ok, s1} = Suppression.suppress(TestRepo, %{org_id: org_id, subscriber_id: Ash.UUID.generate(), reason: "bounce"})
      {:ok, s2} = Suppression.suppress(TestRepo, %{org_id: org_id, subscriber_id: Ash.UUID.generate(), reason: "complaint"})

      rows = Suppression.list_for_org(TestRepo, org_id)
      ids = Enum.map(rows, & &1.id)

      assert s1.id in ids
      assert s2.id in ids
      assert Enum.at(rows, 0).id == s2.id
    end

    test "RED: a sibling org's suppressions never appear (org-bounded)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      {:ok, _mine} = Suppression.suppress(TestRepo, %{org_id: org_a, subscriber_id: Ash.UUID.generate(), reason: "bounce"})
      {:ok, theirs} = Suppression.suppress(TestRepo, %{org_id: org_b, subscriber_id: Ash.UUID.generate(), reason: "bounce"})

      rows = Suppression.list_for_org(TestRepo, org_a)

      refute Enum.any?(rows, &(&1.id == theirs.id))
    end

    test "an org with no suppressions reads an empty (never crashing) list" do
      assert Suppression.list_for_org(TestRepo, Ash.UUID.generate()) == []
    end
  end
end
