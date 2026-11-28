defmodule PawChart.OrgIdPinnedGuardTest do
  @moduledoc """
  Guard: on EVERY resource of every pawchart domain an authorized update cannot change `org_id` and an
  authorized create cannot use another organisation's (`Samen.Policy.OrgIdPinned`, added to every
  resource with an `org_id` by `Samen.Transformers.OrgIdPinned`). Fail-closed: zero resources walked,
  a resource that cannot be exercised, or a violation fails the test, by name.
  """
  use ExUnit.Case, async: true

  # Resources that legitimately need a mutable org_id, each with its reason. None.
  @exceptions %{}

  # An action that sets `org_id` inside a `before_action` hook has no `org_id` on the changeset the walk
  # builds, so the walk cannot see its pin: it is listed here with the an authorized org-A actor cannot file a send under org BD test that proves a foreign org is
  # refused (the walk fails on an unlisted one, or on a listed one whose test is not in its file).
  @hook_set %{
    {PawChart.Marketing.Send, :create_checked} => %{
      reason: "takes the org as an `org_id` argument and copies it into the row in a before_action hook",
      test_file: "../samen_core/test/send_pin_hook_order_test.exs",
      test_name: "an authorized org-A actor cannot file a send under org B"
    }
  }

  test "no resource lets an authorized actor move or file a row under another org_id" do
    report =
      Samen.OrgIdPinnedGuard.walk(Application.fetch_env!(:pawchart, :ash_domains), @exceptions,
        hook_set: @hook_set
      )

    assert report.walked > 0, "the walk visited no resource: the guard is vacuous"
    assert report.actions > 0
    assert report.unexercisable == [], "resources the guard could not exercise: #{inspect(report.unexercisable)}"
    assert report.violations == [], "org_id is not pinned on: #{inspect(report.violations)}"
    assert report.exceptions == @exceptions
    assert report.hook_set_unlisted == [], "actions that set org_id in a hook and are not listed: #{inspect(report.hook_set_unlisted)}"
    assert report.hook_set_unproven == [], "hook-set actions without a named proof: #{inspect(report.hook_set_unproven)}"
    assert PawChart.Repo in report.watched_repos
  end
end
