defmodule Demo.ApiKeyScopeGuardTest do
  @moduledoc """
  Guards for API-key scope enforcement on this host: every resource exposed over JSON:API carries the scope policy
  FIRST (so a later `bypass` cannot skip it), and no two domains of the JSON:API router share a scope family.
  """
  use ExUnit.Case, async: true

  @app :demo
  @router DemoWeb.Api.Router

  test "every JSON:API resource has the key-scope policy as its first policy (and the walk saw them)" do
    report = Samen.ApiKeyScopeGuard.report(Application.fetch_env!(@app, :ash_domains))

    assert report.walked > 0
    assert report.exposed != [], "the walk found no JSON:API resource: it would pass vacuously"
    assert report.unguarded == []
  end

  test "the guard is refutable: a resource without the policy is reported" do
    assert Samen.ApiKeyScopeGuard.guarded?(Demo.Crm.Contact)
    refute Samen.ApiKeyScopeGuard.guarded?(Demo.Identity.ApiKey)
  end

  test "scope families are unique per router" do
    assert Samen.ApiKeyScopeGuard.families(@router) != %{}
    assert Samen.ApiKeyScopeGuard.duplicate_families(@router) == []
    assert Samen.ApiKeyScopeGuard.dotted_families(@router) == []
  end
end
