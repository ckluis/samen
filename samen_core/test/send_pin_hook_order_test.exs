defmodule Samen.SendPinHookOrderTest do
  @moduledoc """
  The behavioural proof for `Marketing`'s `Send.:create_checked`, the one action the org_id pin walk
  (`Samen.OrgIdPinnedGuard`) cannot exercise: it takes the org as an ARGUMENT and copies it into the row in a
  `before_action` hook, so the walk's build never carries a foreign `org_id`. What stops an authorized org-A
  actor filing a send under org B (for a subscriber that really lives in B, so the same-org lookup agrees) is
  the pinned-org recheck that runs AFTER the hook. Every host that mounts Marketing lists this test in its
  guard's `hook_set:` (the blueprint is one macro; this mount is `sx*`).
  """
  use ExUnit.Case, async: false

  alias Samen.Scope
  alias SamenCore.Support.SuppressionFixture.{Send, Subscriber}
  alias SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    :ok
  end

  defp subscriber!(org_id, email) do
    Subscriber
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, email: email, status: :active, source: "test"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp send_as(scope, subscriber_id, org_id) do
    Send
    |> Ash.Changeset.for_create(:create_checked, %{subscriber_id: subscriber_id, org_id: org_id}, scope: scope)
    |> Ash.create(scope: scope)
  end

  test "an authorized org-A actor cannot file a send under org B: refused by the org pin, no row; own-org send succeeds" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope = Scope.new(%{id: Ash.UUID.generate(), org_id: org_a, role: :admin})
    sub_a = subscriber!(org_a, "own@a.example")
    sub_b = subscriber!(org_b, "foreign@b.example")

    # positive control: the same actor, its own org, its own subscriber
    assert {:ok, _} = send_as(scope, sub_a.id, org_a)

    assert {:error, %Ash.Error.Invalid{errors: errors}} = send_as(scope, sub_b.id, org_b)

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :org_id and (Map.get(e, :message) || "") =~ "acting organisation's own"
           end),
           "expected the org_id pin to refuse, got: #{inspect(errors)}"

    refute Enum.any?(Ash.read!(Send, authorize?: false), &(&1.subscriber_id == sub_b.id)),
           "no send row may reference the org-B subscriber"
  end
end
