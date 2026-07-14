defmodule Samen.AnalyticsTrackTest do
  @moduledoc """
  WS-B / Phase B7 (ADR-021) — the capture primitive `Samen.Analytics.track/1` and
  its PII-refusal-at-capture red-path (AC-G12-2 / RP-A1), tested in isolation from
  any host `pae` resource (the refusal gates return BEFORE the write, so no repo).

  The demo `analytics_capture_test.exs` covers AC-G12-1 (a valid event writes ONE
  bounded `pae` row) + best-effort against the real resource. This suite proves the
  three default-deny gates + the anti-tautology (bypassing the classifier flips a
  refusal to a leak).
  """
  use ExUnit.Case, async: false

  alias Samen.Analytics

  setup do
    # No pae resource wired here — track/1 is INERT (returns {:ok, :dropped}) for a
    # VALID payload that passes every gate, so a {:ok, :dropped} means "the payload
    # was ACCEPTED and would have been written". An {:error, _} means REFUSED. This
    # is the clean discriminator the refusal red-path needs, no DB required.
    prior = Application.get_env(:samen_core, Samen.Analytics)
    Application.delete_env(:samen_core, Samen.Analytics)
    on_exit(fn -> if prior, do: Application.put_env(:samen_core, Samen.Analytics, prior) end)
    :ok
  end

  describe "the catalog gate (Gate 1 — unregistered event name refused)" do
    test "a registered event name is accepted (passes to the inert write)" do
      assert {:ok, :dropped} =
               Analytics.track(%{org_id: "org-1", event_name: "session.signed_in"})
    end

    test "an UNREGISTERED event name is refused" do
      assert {:error, :unregistered_event} =
               Analytics.track(%{org_id: "org-1", event_name: "totally.made.up"})
    end

    test "a missing event name is refused" do
      assert {:error, :missing_event_name} = Analytics.track(%{org_id: "org-1"})
    end

    test "a missing org id is refused" do
      assert {:error, :missing_org_id} = Analytics.track(%{event_name: "session.signed_in"})
    end
  end

  describe "the prop-key gate (Gate 2 — unregistered prop key refused)" do
    test "registered props for the event are accepted" do
      assert {:ok, :dropped} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 props: %{"resource" => "crm.contact"}
               })
    end

    test "a freeform / unregistered prop key is refused (default-deny keys)" do
      assert {:error, {:unregistered_prop_key, "note"}} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 props: %{"note" => "call Alice back"}
               })
    end

    test "a registered event with an empty props map is accepted" do
      assert {:ok, :dropped} =
               Analytics.track(%{org_id: "org-1", event_name: "first_run.completed", props: %{}})
    end
  end

  describe "AC-G12-2 / RP-A1 — the PII-refusal-at-capture red-path (Gate 3)" do
    # The refusal gate is on the VALUE of a registered key. `search.used` declares
    # `surface` + `result_count` — we probe PII-shaped values in `surface`.
    test "an email-shaped prop value is REFUSED (:pii_rejected), never written" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "alice@example.com"}
               })
    end

    test "a space-separated-name-shaped value is refused" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "Alice Anders"}
               })
    end

    test "a phone-shaped value is refused" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "+1-800-555-1234"}
               })
    end

    test "an SSN-shaped value is refused" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "123-45-6789"}
               })
    end

    test "a vault token (vt_*) laundered into a prop value is refused" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "vt_abc123deadbeef"}
               })
    end

    test "a nested map value (freeform structure) is refused (default-deny)" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => %{"nested" => "thing"}}
               })
    end

    test "a bounded scalar value (a count) is ACCEPTED — the over-block guard" do
      # Proves the refusal is DISCRIMINATING, not a blanket refuse-all: a legitimate
      # bounded value passes (like the CDC projection's RP-G3-3 over-block guard).
      assert {:ok, :dropped} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "search.used",
                 props: %{"surface" => "crm", "result_count" => 12}
               })
    end
  end

  describe "the entity_ref gate (Gate 4 — REFUSAL SYMMETRY, B9 carry B7-P2-1)" do
    # B7 shipped entity_ref with a silent scrub-to-nil (the rest of the row still
    # wrote) — asymmetric with the prop-value gate. Fail-closed now: a PII-shaped /
    # vault-token / structured entity_ref refuses the WHOLE event.
    test "an email-shaped entity_ref REFUSES the whole event — never a silent scrub-to-nil" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 entity_ref: "alice@example.com"
               })
    end

    test "a space-separated-name-shaped entity_ref is refused" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 entity_ref: "Alice Anderson"
               })
    end

    test "a vault token (vt_*) entity_ref is refused — a laundered vaulted value must not ride token-shaped" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 entity_ref: "vt_abc123deadbeef"
               })
    end

    test "a structured entity_ref (map) is refused outright — an entity_ref is an opaque bounded scalar handle" do
      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 entity_ref: %{"email" => "alice@example.com"}
               })
    end

    test "the discriminating pair: an opaque bounded ref is ACCEPTED (the over-block guard)" do
      # The refusal discriminates — a legitimate opaque handle and a uuid both pass.
      assert {:ok, :dropped} =
               Analytics.track(%{org_id: "org-1", event_name: "record.created", entity_ref: "rec-42"})

      assert {:ok, :dropped} =
               Analytics.track(%{
                 org_id: "org-1",
                 event_name: "record.created",
                 entity_ref: "018f3a2e-6f7c-7a9b-8c1d-2e3f4a5b6c7d"
               })
    end

    test "an absent or empty entity_ref is fine (nil — accepted, nothing to classify)" do
      assert {:ok, :dropped} = Analytics.track(%{org_id: "org-1", event_name: "record.created"})
      assert {:ok, :dropped} = Analytics.track(%{org_id: "org-1", event_name: "record.created", entity_ref: ""})
    end
  end

  describe "AC-G12-2 anti-tautology — the classifier is load-bearing" do
    # Two payloads identical EXCEPT the prop value's PII shape: the PII-shaped one is
    # refused, the bounded one is accepted. A classifier that did nothing would accept
    # BOTH — so the discriminating pair proves the refusal is non-vacuous.
    test "the discriminating pair: PII value refused, bounded value accepted" do
      pii = Analytics.track(%{org_id: "o", event_name: "search.used", props: %{"surface" => "a@b.com"}})
      ok = Analytics.track(%{org_id: "o", event_name: "search.used", props: %{"surface" => "crm"}})

      assert pii == {:error, :pii_rejected}
      assert ok == {:ok, :dropped}
      refute pii == ok, "a no-op classifier would make these equal — the refusal must discriminate"
    end
  end

  describe "best-effort — track/1 never raises" do
    test "a malformed request returns an error tuple, never raises" do
      assert {:error, :invalid_request} = Analytics.track("not a map")
    end

    test "a nil props is treated as empty (accepted)" do
      # Map.get defaults to %{} — a request without :props is valid.
      assert {:ok, :dropped} = Analytics.track(%{org_id: "o", event_name: "session.signed_in"})
    end
  end
end
