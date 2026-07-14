defmodule Samen.AnalyticsSourcesTest do
  @moduledoc """
  WS-B / Phase B7 (design §4.2) — the framework event SOURCES build bounded,
  catalog-valid, token-blind payloads and hand them to `track/1`. With no `pae`
  resource wired, a valid source call returns `{:ok, :dropped}` (accepted → would
  write); a source that forwarded a PII-shaped value would be REFUSED. Every source
  is best-effort (never raises).
  """
  use ExUnit.Case, async: false

  alias Samen.Analytics.Sources

  setup do
    prior = Application.get_env(:samen_core, Samen.Analytics)
    Application.delete_env(:samen_core, Samen.Analytics)
    on_exit(fn -> if prior, do: Application.put_env(:samen_core, Samen.Analytics, prior) end)
    :ok
  end

  test "session_signed_in/2 builds an accepted session.signed_in payload" do
    assert {:ok, :dropped} = Sources.session_signed_in("org-1")
    assert {:ok, :dropped} = Sources.session_signed_in("org-1", "subject-uuid")
  end

  test "first_run_completed/1 builds an accepted first_run.completed payload" do
    assert {:ok, :dropped} = Sources.first_run_completed("org-1")
  end

  test "record_created/3 reduces a module to a bounded resource label (not a full path)" do
    # A module name → its LAST segment underscored (a bounded label), so the prop is
    # a low-cardinality enum-ish value, never a freeform string the classifier rejects.
    assert {:ok, :dropped} =
             Sources.record_created("org-1", Demo.CrmScope.Person, entity_ref: "rec-123")
  end

  test "record_created/3 accepts a bounded string resource label" do
    assert {:ok, :dropped} = Sources.record_created("org-1", "contact", entity_ref: "rec-9")
  end

  test "search_used/3 carries a bounded surface + count, never query text" do
    assert {:ok, :dropped} = Sources.search_used("org-1", :crm, result_count: 7)
    assert {:ok, :dropped} = Sources.search_used("org-1", "support")
  end

  test "sources are best-effort — a nil org id is refused, not raised" do
    assert {:error, :missing_org_id} = Sources.session_signed_in(nil)
  end
end
