defmodule Demo.AnalyticsCaptureTest do
  @moduledoc """
  WS-B / Phase B7 (ADR-021) integration proof of the product-event capture primitive
  on the DEMO host's real Postgres + `pae` ledger:

    * AC-G12-1 — `Samen.Analytics.track/1` writes EXACTLY ONE bounded `pae` row for a
      valid event; best-effort (a track failure never fails the primary write).
    * AC-G12-3 — `pae` is token-blind: `Cdc.Projection.project(ProductEvent)` returns
      ALL columns (with the `non_pii!` clearances that record the capture-time
      guarantee); a NON-projected physical column would violate the cdc_mirror oracle
      tier. The physical table carries no `pii_`-prefixed column.
    * AC-G12-5 — `pae_actor_ref` is a per-subject HMAC pseudonym (NOT a raw id);
      post-shred `WideEvent.for_subject/2` returns `:shredded` — the pseudonym is
      unreconstructable, so the row's actor linkage unlinks across live + mirror at
      once (erasure for free; `pae` is org-scoped-only with NO subject column).
    * AC-G6-8 — a feature-flag variant assignment flows to `track/1` (the §3.4 seam)
      and lands ONE `flag.assignment` `pae` row via the configured emitter.
  """
  use Demo.DataCase, async: false

  alias Demo.Analytics.ProductEvent
  alias Samen.{Analytics, Cdc, Kms, WideEvent}

  require Ash.Query

  setup do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    # The token-blind clearances (pae_props / pae_actor_ref / pae_entity_ref) — the
    # physical-tier record of track/1's capture-time PII refusal. Registered here as
    # the primitives/billing scopes register theirs (idempotent).
    :ok = Demo.Analytics.NonPiiSetup.register_all()
    :ok
  end

  defp events(org_id) do
    ProductEvent
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([
      :org_id,
      :actor_ref,
      :event_name,
      :event_kind,
      :entity_ref,
      :props,
      :occurred_at
    ])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "AC-G12-1 — track/1 writes exactly one bounded pae row" do
    test "a valid record.created event writes one row with bounded fields" do
      org_id = Ash.UUID.generate()

      assert {:ok, %ProductEvent{} = pae} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 entity_ref: "rec-42",
                 props: %{"resource" => "crm.contact"}
               })

      assert pae.event_name == :"record.created"
      assert pae.event_kind == :record
      assert pae.entity_ref == "rec-42"
      assert pae.props == %{"resource" => "crm.contact"}

      rows = events(org_id)
      assert length(rows) == 1
      assert hd(rows).org_id == org_id
    end

    test "a subject_id is pseudonymized to actor_ref (never stored raw)" do
      org_id = Ash.UUID.generate()
      subject_id = Ash.UUID.generate()
      {:ok, _} = Kms.adapter().generate_subject_key(subject_id)

      {:ok, pae} =
        Analytics.track(%{
          org_id: org_id,
          event_name: "session.signed_in",
          subject_id: subject_id
        })

      # actor_ref is the HMAC pseudonym — NOT the raw subject id, and it matches
      # WideEvent.for_subject/2 (the same one-way handle).
      refute pae.actor_ref == subject_id
      assert {:ok, pseudonym} = WideEvent.for_subject(subject_id)
      assert pae.actor_ref == pseudonym
    end

    test "an unregistered event name writes NO row (refused at capture)" do
      org_id = Ash.UUID.generate()
      assert {:error, :unregistered_event} =
               Analytics.track(%{org_id: org_id, event_name: "made.up"})

      assert events(org_id) == []
    end

    test "a PII-shaped prop writes NO row (AC-G12-2 refusal reaches the ledger boundary)" do
      org_id = Ash.UUID.generate()

      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "search.used",
                 props: %{"surface" => "alice@example.com"}
               })

      assert events(org_id) == [], "a refused PII payload must never reach pae"
    end

    test "a PII-shaped entity_ref writes NO row (refusal symmetry, B9 carry B7-P2-1 — no partial row from a silent scrub)" do
      org_id = Ash.UUID.generate()

      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 entity_ref: "alice@example.com",
                 props: %{"resource" => "crm.contact"}
               })

      # The OLD scrub persisted this row with entity_ref: nil. Fail-closed: nothing.
      assert events(org_id) == [], "a refused entity_ref must refuse the WHOLE event, never persist a scrubbed row"
    end
  end

  describe "AC-G12-3 — pae is token-blind by construction" do
    test "project(ProductEvent) returns ALL physical columns (no plaintext excluded)" do
      classified = Cdc.Projection.classify_columns(ProductEvent)
      projected = Cdc.Projection.project(ProductEvent) |> Enum.map(&elem(&1, 0))
      all = Enum.map(classified, &elem(&1, 0))

      excluded = all -- projected

      assert excluded == [],
             "every pae column must project (a non-projected column is a cdc_mirror " <>
               "oracle violation, AC-G12-3); excluded: #{inspect(excluded)}"

      # No column classifies :plaintext_pii — token-blind end to end.
      refute Enum.any?(classified, fn {_c, k} -> k == :plaintext_pii end)
    end

    test "the physical table carries no pii_-prefixed column" do
      {:ok, %{columns: cols}} = Repo.query("SELECT * FROM pae_product_event LIMIT 0")
      refute Enum.any?(cols, &String.starts_with?(&1, "pii_"))
      # No subject-identity column. `pae_event_name` is a BOUNDED ENUM label (the
      # catalog name), not a person's name — exclude it from the identity-hint scan.
      identity_cols = Enum.reject(cols, &(&1 == "pae_event_name"))
      refute Enum.any?(identity_cols, fn c -> c =~ "name" or c =~ "email" or c =~ "phone" or c =~ "address" end)
    end

    test "RP anti-tautology — the projection genuinely EXCLUDES an UNCLEARED freeform map" do
      # The "all pae columns project" assertion is non-vacuous ONLY because a freeform
      # column WOULD fail to project absent a clearance. Prove the mechanism is
      # load-bearing: pae_props classifies plaintext_pii (excluded) WITHOUT its
      # clearance, and metadata (projected) WITH it. A no-op projector would treat both
      # the same — the discriminating pair proves it does not.
      entry = [%{table_name: "pae_product_event", column_name: "pae_props", cleared_by: "a", reviewed_by: "b"}]

      cleared = Cdc.Projection.classify_columns(ProductEvent, non_pii_entries: entry) |> Map.new()
      uncleared = Cdc.Projection.classify_columns(ProductEvent, non_pii_entries: []) |> Map.new()

      assert cleared["pae_props"] == :metadata, "with the clearance, pae_props projects"

      assert uncleared["pae_props"] == :plaintext_pii,
             "without the clearance, a freeform map is REFUSED — the exclusion is real"

      refute cleared["pae_props"] == uncleared["pae_props"],
             "the clearance is load-bearing; a no-op projector would make these equal"
    end
  end

  describe "AC-G12-5 — erasure for free (the pseudonym unlinks post-shred)" do
    test "post-shred, actor_ref is unreconstructable (for_subject returns :shredded)" do
      org_id = Ash.UUID.generate()
      subject_id = Ash.UUID.generate()
      {:ok, _} = Kms.adapter().generate_subject_key(subject_id)

      {:ok, pae} =
        Analytics.track(%{org_id: org_id, event_name: "session.signed_in", subject_id: subject_id})

      # Pre-shred: the pseudonym is computable and matches the stored actor_ref.
      assert {:ok, pseudonym} = WideEvent.for_subject(subject_id)
      assert pae.actor_ref == pseudonym

      # Shred the subject's KMS DEK.
      {:ok, _} = Kms.adapter().shred(subject_id)

      # Post-shred: the pseudonym is unreconstructable — nobody (not even the operator)
      # can re-derive actor_ref → subject_id. The pae row still holds the ORG-scoped
      # fact, but its actor linkage is gone across live + mirror simultaneously.
      assert {:error, :shredded} = WideEvent.for_subject(subject_id)

      # And pae is org-scoped-only: there is NO subject column to redact — the erasure
      # is STRUCTURAL (the key destruction IS the erasure), not a row rewrite.
      {:ok, %{columns: cols}} = Repo.query("SELECT * FROM pae_product_event LIMIT 0")
      refute "pae_subject_id" in cols
    end
  end

  describe "AC-G6-8 — a flag variant assignment flows to pae (the §3.4 seam)" do
    test "evaluate/2 with a variant assignment lands one flag.assignment pae row" do
      org_id = Ash.UUID.generate()

      loader = fn "exp" ->
        {:ok, %{enabled: true, rollout_pct: 100, variants: %{"a" => 50, "b" => 50}}}
      end

      # The configured emitter is {Samen.Analytics, :track} (config.exs) — so the
      # assignment flows to the real pae ledger with zero call-site changes.
      d = Samen.FeatureFlags.evaluate("exp", %{org_id: org_id}, loader: loader)
      assert d.on
      assert d.variant in [:a, :b]

      rows = events(org_id)
      assert length(rows) == 1
      [row] = rows
      assert row.event_name == :"flag.assignment"
      assert row.event_kind == :experiment
      assert row.props["flag_name"] == "exp"
      assert row.props["variant"] == to_string(d.variant)
      assert row.org_id == org_id
    end
  end

  describe "best-effort — a capture failure never aborts the caller" do
    test "an invalid request returns an error tuple, never raises" do
      assert {:error, :invalid_request} = Analytics.track(:not_a_map)
    end
  end

end
