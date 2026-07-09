defmodule Samen.SuppressionPortableTest do
  @moduledoc """
  ADR-014 §4 RP-D3 — the kernel suppression check must be PORTABLE across mount abbrevs.

  Covers AC-G2-4: Marketing mounted under a NON-`msp` abbrev (here `sx*`) with an active
  suppression row REFUSES the send — no crash, no silent bypass — because the suppression
  table is derived from the blueprint's own abbrev (via an OrgScope-inheriting Ash read on
  THIS mount's `Suppression` resource), not the old hardcoded `msp_suppression`.

  The old kernel hardcoded `SELECT ... FROM msp_suppression`. Under `sx*` that table does
  not exist, so the old code SILENTLY bypassed suppression (query error → `false` →
  "not suppressed" → send allowed). This suite pins the fix and its discriminating twin.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo
  alias Samen.Scope

  alias SamenCore.Support.SuppressionFixture.{Send, Subscriber, Suppression}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp scope_for(org_id), do: Scope.new(%{id: Ash.UUID.generate(), org_id: org_id, role: :admin})

  defp create_subscriber!(org_id, email) do
    Subscriber
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, email: email, status: :active, source: "test"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp suppress!(org_id, subscriber_id) do
    Suppression
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        subscriber_id: subscriber_id,
        reason: :unsubscribed,
        active: true,
        suppressed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp attempt_send(org_id, subscriber_id) do
    scope = scope_for(org_id)

    Send
    |> Ash.Changeset.for_create(
      :create_checked,
      %{subscriber_id: subscriber_id, org_id: org_id},
      scope: scope
    )
    |> Ash.create()
  end

  describe "AC-G2-4 · suppression is portable under a non-msp mount abbrev (sx*)" do
    test "an ACTIVE suppression row REFUSES the send (no crash, no silent bypass)" do
      org_id = Ash.UUID.generate()
      sub = create_subscriber!(org_id, "suppressed@sx.example")
      _ = suppress!(org_id, sub.id)

      # The load-bearing assertion: the send is REFUSED. If the kernel still hit
      # `msp_suppression`, the query would error under the `sxp` mount, the check would
      # fall through to "not suppressed", and this send would (wrongly) SUCCEED.
      assert {:error, %Ash.Error.Invalid{} = err} = attempt_send(org_id, sub.id)
      assert Enum.any?(err.errors, &(Map.get(&1, :message) == "suppressed"))

      # No send row was written (the refusal happens before insert).
      assert [] = Ash.read!(Send, actor: %{org_id: org_id, role: :admin}, authorize?: false)
    end

    test "DISCRIMINATING — a NON-suppressed subscriber's send SUCCEEDS (not always-fail)" do
      org_id = Ash.UUID.generate()
      sub = create_subscriber!(org_id, "clear@sx.example")

      assert {:ok, send} = attempt_send(org_id, sub.id)
      assert send.subscriber_id == sub.id
      assert send.status == :queued

      # The send row is persisted in THIS org (proves the write landed under the sx* mount).
      [persisted] =
        Send
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected([:org_id, :subscriber_id, :status])
        |> Ash.read!(actor: %{org_id: org_id, role: :admin}, authorize?: false)

      assert persisted.org_id == org_id
    end

    test "a DEACTIVATED suppression row does NOT block the send (active=false)" do
      org_id = Ash.UUID.generate()
      sub = create_subscriber!(org_id, "reactivated@sx.example")

      Suppression
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, subscriber_id: sub.id, reason: :bounced, active: false},
        authorize?: false
      )
      |> Ash.create!()

      assert {:ok, _send} = attempt_send(org_id, sub.id)
    end

    test "OrgScope inheritance — org B's suppression row does NOT block org A's send" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      # Same subscriber id lives in each org's table row; org B suppresses ITS subscriber.
      sub_a = create_subscriber!(org_a, "shared@sx.example")
      sub_b = create_subscriber!(org_b, "shared@sx.example")
      _ = suppress!(org_b, sub_b.id)

      # org A's send is unaffected by org B's suppression list (the Ash read is org-scoped).
      assert {:ok, _send} = attempt_send(org_a, sub_a.id)
    end
  end
end
