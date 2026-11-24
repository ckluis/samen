defmodule Demo.OrgIdPinnedGuardTest do
  @moduledoc """
  Guard: on EVERY resource of every demo domain an authorized update cannot change `org_id` and an
  authorized create cannot use another organisation's (`Samen.Policy.OrgIdPinned`, added to every
  resource with an `org_id` by `Samen.Transformers.OrgIdPinned`). Fail-closed: zero resources walked,
  a resource that cannot be exercised, or a violation fails the test, by name.
  """
  use ExUnit.Case, async: true

  # Resources that legitimately need a mutable org_id, each with its reason. None.
  @exceptions %{}

  test "no resource lets an authorized actor move or file a row under another org_id" do
    report = Samen.OrgIdPinnedGuard.walk(Application.fetch_env!(:demo, :ash_domains), @exceptions)

    assert report.walked > 0, "the walk visited no resource: the guard is vacuous"
    assert report.actions > 0
    assert report.unexercisable == [], "resources the guard could not exercise: #{inspect(report.unexercisable)}"
    assert report.violations == [], "org_id is not pinned on: #{inspect(report.violations)}"
    assert report.exceptions == @exceptions
  end
end
