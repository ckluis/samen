defmodule Samen.Erasure.CompletenessTest do
  @moduledoc """
  ADR-046 §6 — the erasure-completeness CAPSTONE gate (`Samen.Erasure.Completeness` +
  `mix samen.verify.erasure_completeness`).

  `Samen.Erasure.shred/2` is a KEY-destruction job — a value living OUTSIDE the
  per-subject-DEK envelope is not reached by key destruction, so it needs an explicit
  erasure arm or a shredded subject's data survives. This gate DISCOVERS every such
  residue from the LIVE schema (never `schema.dict`, which grandfathers) and ASSERTS a
  registered subject_id-keyed arm reaches each.

  Proven here, with anti-tautology positive controls:

    * DISCOVERY is real + non-vacuous — the fixture residue set contains ≥ the two hard
      classes (a `_bidx` derived-linkable column AND a `storage_key` column), and PHYSICAL
      (abbrev-prefixed) columns are resolved, not logical names.
    * PASSES on the fully-registered tree — every residue reached by a derived spec.
    * FAILS per-class when an arm is removed — drop the bidx spec → the email_bidx residue
      is named UNREACHED (positive control: with the spec it passes); drop the file spec →
      the storage_key residue is named UNREACHED.
    * FAILS on an UNREGISTERED `_bidx` column — the structural backstop catches a future
      blind index not in `Samen.DerivedLinkable`.
    * FAILS CLOSED on empty discovery — an empty derived-linkable OR storage_key set is a
      broken verifier, never a pass.
    * ACTIVATION — `default_specs/1` derives the correct subject-keyed arms from the live
      schema, and `install_default_specs/1` registers them so the arms actually fire.
  """
  use ExUnit.Case, async: false

  alias Samen.Erasure
  alias Samen.Erasure.Completeness

  alias SamenCore.Support.Completeness.{
    Credential,
    AuthToken,
    File,
    Attachment,
    OrgAsset,
    Bag,
    RogueBidx
  }

  # The clean, fully-coverable residue population (no unregistered rogue column).
  @clean [Credential, AuthToken, File, OrgAsset, Bag]

  # + an about-a-subject blob (CRM.Attachment analogue: storage_key + a domain subject-FK
  # `person_id`) alongside the org-owned Media analogue (OrgAsset) — ADR-046 §7 #5.
  @with_attachment [Credential, AuthToken, File, Attachment, OrgAsset, Bag]

  defp derived_specs, do: Erasure.default_specs(resources: @clean)

  # ADR-048 §7.3 (C4): `derived_summary` JOINED `check/1`'s HARD non-vacuity floor, so a
  # resource set carrying no vault-routed transcript surface now fails closed BEFORE any
  # per-class arm is judged. Every `check/1` below therefore runs over a set that includes
  # the transcript-bearing `Samen.AI.Agent.Run` — the same shape a real host has — with the
  # retention arm that covers it. The fixture lists themselves stay transcript-free so the
  # discovery-difference arm below can still measure the class BY ITS ABSENCE.
  defp with_transcript(resources), do: [Samen.AI.Agent.Run | resources]

  defp check(resources, extra \\ []) do
    specs = derived_specs()
    resources = with_transcript(resources)
    retention = Erasure.default_specs(resources: resources).retention_specs

    Completeness.check(
      Keyword.merge(
        [
          resources: resources,
          bidx_specs: specs.blind_index_erasure_specs,
          file_specs: specs.file_erasure_specs,
          retention_specs: retention,
          skip_bag_guard?: true
        ],
        extra
      )
    )
  end

  # ======================================================================
  # DISCOVERY — real, non-vacuous, PHYSICAL columns
  # ======================================================================

  test "discovery finds the real residue set from the live schema (physical columns)" do
    residues = Completeness.discover(resources: @clean)

    # Derived-linkable: BOTH bidx columns, discovered by their PHYSICAL (prefixed) source.
    dl_cols = residues.derived_linkable |> Enum.map(& &1.column) |> Enum.sort()
    assert dl_cols == ["atc_sent_to_bidx", "cpc_email_bidx"]

    # Each registered column resolves its owning-principal PHYSICAL subject column.
    cred = Enum.find(residues.derived_linkable, &(&1.column == "cpc_email_bidx"))
    assert cred.registered?
    assert cred.subject_column == "cpc_id"

    tok = Enum.find(residues.derived_linkable, &(&1.column == "atc_sent_to_bidx"))
    assert tok.registered?
    assert tok.subject_column == "atc_credential_id"

    # storage_key: both columns; File subject-linked, OrgAsset not.
    sk_cols = residues.storage_key |> Enum.map(& &1.column) |> Enum.sort()
    assert sk_cols == ["fil_storage_key", "med_storage_key"]

    file = Enum.find(residues.storage_key, &(&1.resource == File))
    assert file.subject_field == :uploaded_by_id
    assert Enum.find(residues.storage_key, &(&1.resource == OrgAsset)).subject_field == nil

    # custom bag discovered.
    assert Enum.any?(residues.custom_bag, &(&1.column == "bag_custom"))
  end

  # ======================================================================
  # PASSES on the fully-registered tree
  # ======================================================================

  test "check passes when every discovered residue is reached by a derived arm" do
    assert {:ok, report} = check(@clean)

    assert report.derived_linkable.count == 2
    assert report.storage_key.count == 2
    # OrgAsset is reported as an org-lifecycle residual, never a violation.
    assert report.org_asset_residuals != []
    assert Enum.any?(report.org_asset_residuals, &(&1 =~ "OrgAsset"))
  end

  test "check exercises the LIVE custom-bag define-time erasability guard (no repo needed)" do
    # skip_bag_guard? false → the real probe: a pii_declared field on an un-covered table
    # MUST be refused by Samen.CustomFields.define_field/2 (the guard runs before any DB
    # insert). Proves the erasure-by-construction mechanism is live.
    assert {:ok, report} = check(@clean, skip_bag_guard?: false)
    assert report.custom_bag.erasure_guard == true
    assert report.custom_bag.masking_arm == true
    # I1 (ADR-046 §8 residual #2): the custom-OBJECT record-bag rung of the SAME guard is
    # ALSO live — a pii_declared field on a `tnt$obj$…` object table with no record-bag arm
    # is refused, closing the analogue escape.
    assert report.custom_bag.object_bag_guard == true
  end

  # ======================================================================
  # I1 — custom-OBJECT record-bag define-time guard (ADR-046 §8 residual #2)
  # ======================================================================

  test "the custom-OBJECT record-bag guard arm is REFUTABLE (a neutered object-guard is named)" do
    # Positive control: with the live guard the tree passes (proven above).
    assert {:ok, _} = check(@clean, skip_bag_guard?: false)

    # Model the gap: the object-bag guard no longer refuses a pii_declared tnt$obj$ field
    # (the blanket exemption restored). The gate MUST name the un-enforced object-bag rung —
    # proving the arm is not a tautology.
    assert {:error, {:incomplete, violations, _}} =
             check(@clean, skip_bag_guard?: false, object_guard_fun: fn -> false end)

    assert Enum.any?(
             violations,
             &(&1 =~ "custom-OBJECT record-bag ERASURE guard not enforced")
           )
  end

  # ======================================================================
  # I2 — retention :delete generic-purge blob routing (ADR-046 §8 residual #3)
  # ======================================================================

  test "every storage_key residue is retention-blob-aware (routes :delete through the chokepoint)" do
    assert {:ok, report} = check(@clean)
    assert report.storage_key.retention_blob_aware == true
  end

  test "the retention-blob-aware arm is REFUTABLE (an un-routed storage_key blob is named)" do
    # Positive control: with the live routing predicate the tree passes.
    assert {:ok, _} = check(@clean)

    # Model the gap: retention's :delete no longer routes any storage_key blob through the
    # governed chokepoint. BOTH the subject-linked File AND the org-asset Media blob must be
    # named UN-PURGED (a raw destroy would orphan the bytes) — proving the arm is not a
    # tautology and covers org-asset blobs too.
    assert {:error, {:incomplete, violations, _}} =
             check(@clean, retention_blob_backed_fun: fn _ -> false end)

    assert Enum.any?(violations, &(&1 =~ "UN-PURGED storage_key blob" and &1 =~ "fil_storage_key"))
    assert Enum.any?(violations, &(&1 =~ "UN-PURGED storage_key blob" and &1 =~ "med_storage_key"))
  end

  # ======================================================================
  # FAILS per-class when an arm is removed (+ positive controls)
  # ======================================================================

  test "removing the blind-index arm makes the email_bidx residue UNREACHED (refutable)" do
    # Positive control: WITH the derived bidx specs, it passes.
    assert {:ok, _} = check(@clean)

    # Drop the blind-index arm → the derived-linkable residues are named unreached.
    assert {:error, {:incomplete, violations, _}} = check(@clean, bidx_specs: [])
    assert Enum.any?(violations, &(&1 =~ "UNREACHED derived-linkable" and &1 =~ "cpc_email_bidx"))
    assert Enum.any?(violations, &(&1 =~ "atc_sent_to_bidx"))
  end

  test "removing the file arm makes the storage_key residue UNREACHED (refutable)" do
    # Positive control: WITH the derived file specs, it passes.
    assert {:ok, _} = check(@clean)

    assert {:error, {:incomplete, violations, _}} = check(@clean, file_specs: [])
    assert Enum.any?(violations, &(&1 =~ "UNREACHED storage_key blob" and &1 =~ "fil_storage_key"))
    # OrgAsset (no subject field) is NEVER a violation — only the subject-linked File is.
    refute Enum.any?(violations, &(&1 =~ "med_storage_key"))
  end

  test "an UNREGISTERED _bidx column fails the gate (structural backstop)" do
    # Include the rogue resource; its handle_bidx is not in Samen.DerivedLinkable.
    assert {:error, {:incomplete, violations, _}} = check([RogueBidx | @clean])

    assert Enum.any?(
             violations,
             &(&1 =~ "UNREGISTERED derived-linkable" and &1 =~ "rog_handle_bidx")
           )
  end

  # ======================================================================
  # FAILS CLOSED on empty discovery (non-vacuity floor)
  # ======================================================================

  test "empty derived-linkable discovery fails closed" do
    # Only a storage_key + bag resource, no _bidx column.
    assert {:error, {:no_residues_discovered, :derived_linkable}} =
             check([File, Bag])
  end

  test "empty storage_key discovery fails closed" do
    # Only a bidx resource, no storage_key column.
    assert {:error, {:no_residues_discovered, :storage_key}} = check([Credential])
  end

  # ======================================================================
  # ACTIVATION — derivation + install register the real subject-keyed arms
  # ======================================================================

  test "default_specs/1 derives the correct subject-keyed arms from the live schema" do
    specs = derived_specs()

    # One blind-index arm per REGISTERED derived-linkable column, physical columns +
    # resolved physical subject columns. Rogue/unregistered columns are NOT derived.
    bidx = Enum.sort_by(specs.blind_index_erasure_specs, & &1.bidx_column)

    assert [
             %{table_name: "atc_auth_token", bidx_column: "atc_sent_to_bidx", subject_column: "atc_credential_id"},
             %{table_name: "cpc_credential", bidx_column: "cpc_email_bidx", subject_column: "cpc_id"}
           ] = Enum.map(bidx, &Map.take(&1, [:table_name, :bidx_column, :subject_column]))

    # One file arm for the subject-linked File; the OrgAsset blob gets NO subject-keyed spec.
    assert [%{file_module: File, subject_field: :uploaded_by_id}] = specs.file_erasure_specs
  end

  # ======================================================================
  # ABOUT-A-SUBJECT blobs — domain subject-FK reach (ADR-046 §7 #5)
  # ======================================================================

  defp check_with_attachment(file_specs) do
    resources = with_transcript(@with_attachment)
    specs = Erasure.default_specs(resources: resources)

    Completeness.check(
      resources: resources,
      bidx_specs: specs.blind_index_erasure_specs,
      file_specs: file_specs || specs.file_erasure_specs,
      retention_specs: specs.retention_specs,
      skip_bag_guard?: true
    )
  end

  test "an about-a-subject person_id storage_key column is GATED subject-linked and derives a person_id arm" do
    # Discovery marks Attachment (domain subject-FK person_id) subject-linked; the org-owned
    # Media analogue (OrgAsset, no subject FK) stays org-scoped.
    residues = Completeness.discover(resources: @with_attachment)
    att = Enum.find(residues.storage_key, &(&1.resource == Attachment))
    assert att.subject_field == :person_id
    assert Enum.find(residues.storage_key, &(&1.resource == OrgAsset)).subject_field == nil

    # default_specs DERIVES a file arm for it keyed on :person_id — cover-by-construction.
    specs = Erasure.default_specs(resources: @with_attachment)

    assert %{file_module: Attachment, subject_field: :person_id} in specs.file_erasure_specs

    # With the derived arms the gate PASSES: Attachment is subject-linked (gated + reached),
    # the org-owned Media analogue is an org-asset residual (NOT gated as subject-linked).
    assert {:ok, report} = check_with_attachment(nil)
    assert Enum.any?(report.storage_key.subject_linked, &(&1 =~ "ath_storage_key"))
    assert Enum.any?(report.org_asset_residuals, &(&1 =~ "OrgAsset"))
    refute Enum.any?(report.org_asset_residuals, &(&1 =~ "Attachment"))
  end

  test "removing the file arm names the about-a-subject person_id blob UNREACHED; org-owned Media stays a residual (refutable)" do
    # Positive control: WITH the derived file arms it passes.
    assert {:ok, _} = check_with_attachment(nil)

    # Drop the file arm → the person_id Attachment blob is named UNREACHED (proving the gate
    # genuinely REQUIRES an arm for an about-a-subject blob, not a tautology).
    assert {:error, {:incomplete, violations, _}} = check_with_attachment([])

    assert Enum.any?(
             violations,
             &(&1 =~ "UNREACHED storage_key blob" and &1 =~ "ath_storage_key" and &1 =~ "person_id")
           )

    # The org-owned Media analogue (no subject FK) is NEVER a violation — it stays correctly
    # org-scoped, never forced into an inappropriate per-subject spec.
    refute Enum.any?(violations, &(&1 =~ "med_storage_key"))
  end

  test "install_default_specs/1 registers the arms into config so they actually fire" do
    prev_bidx = Application.fetch_env(:samen_core, :blind_index_erasure_specs)
    prev_file = Application.fetch_env(:samen_core, :file_erasure_specs)

    # Restore EXACTLY — including DELETING a key that was previously UNSET. Putting `nil`
    # back would poison `Application.get_env(_, _, [])` (it returns nil, not the []
    # default, for a key explicitly set to nil), crashing the arms' `Enum.map` for later
    # tests that run Erasure.shred.
    restore = fn key, prev ->
      case prev do
        {:ok, val} -> Application.put_env(:samen_core, key, val)
        :error -> Application.delete_env(:samen_core, key)
      end
    end

    on_exit(fn ->
      restore.(:blind_index_erasure_specs, prev_bidx)
      restore.(:file_erasure_specs, prev_file)
    end)

    installed = Erasure.install_default_specs(resources: @clean)

    assert Application.get_env(:samen_core, :blind_index_erasure_specs) ==
             installed.blind_index_erasure_specs

    assert Application.get_env(:samen_core, :file_erasure_specs) == installed.file_erasure_specs
    assert length(installed.blind_index_erasure_specs) == 2
    assert length(installed.file_erasure_specs) == 1
  end

  # ======================================================================
  # CLASS (e) — vault-routed transcripts (ADR-047 §7.4, batch A2)
  # ======================================================================

  test "discovery finds the vault-routed run transcript (physical column) — and classes (a)-(c) are BYTE-IDENTICAL with or without it" do
    agent_run = Samen.AI.Agent.Run

    without_agent = Completeness.discover(resources: @clean)
    with_agent = Completeness.discover(resources: [agent_run | @clean])

    # The transcript class discovers the run resource's PHYSICAL vaulted column.
    assert [tr] = with_agent.transcript
    assert tr.resource == agent_run
    assert tr.table == "ai_agent_run"
    assert tr.column == "pii_arn_transcript"
    assert tr.vault == :pii_transcript

    # RP-AG-11: the pre-existing residue classes gain NO member from the agent tables —
    # the transcript is IN-envelope (vault-routed), not a new out-of-envelope residue.
    assert with_agent.derived_linkable == without_agent.derived_linkable
    assert with_agent.storage_key == without_agent.storage_key
    assert with_agent.custom_bag == without_agent.custom_bag
    assert without_agent.transcript == []
  end

  test "RED: removing the retention :shred arm names the transcript UNREACHED (refutable); the derived arm covers it (control)" do
    agent_run = Samen.AI.Agent.Run
    base = derived_specs()
    derived = Erasure.default_specs(resources: [agent_run | @clean])

    # POSITIVE CONTROL: with the DERIVED retention arm (90d :shred keyed :id) it passes.
    assert {:ok, report} =
             Completeness.check(
               resources: [agent_run | @clean],
               bidx_specs: base.blind_index_erasure_specs,
               file_specs: base.file_erasure_specs,
               retention_specs: derived.retention_specs,
               skip_bag_guard?: true
             )

    assert report.transcript.count == 1
    assert report.transcript.covered == ["ai_agent_run.pii_arn_transcript"]

    # The red half: NO retention arm → the transcript is NAMED unreached (the E7 rule —
    # a coverage assertion that cannot fail asserts nothing).
    assert {:error, {:incomplete, violations, _}} =
             Completeness.check(
               resources: [agent_run | @clean],
               bidx_specs: base.blind_index_erasure_specs,
               file_specs: base.file_erasure_specs,
               retention_specs: [],
               skip_bag_guard?: true
             )

    assert Enum.any?(
             violations,
             &(&1 =~ "UNREACHED vault-routed transcript" and &1 =~ "pii_arn_transcript")
           )

    # A NON-:shred / non-self-keyed spec does NOT count as coverage (the arm must be the
    # crypto-shred of the ROW's own DEK, not a row prune under someone else's key).
    assert {:error, {:incomplete, violations2, _}} =
             Completeness.check(
               resources: [agent_run | @clean],
               bidx_specs: base.blind_index_erasure_specs,
               file_specs: base.file_erasure_specs,
               retention_specs: [
                 %{resource: agent_run, ttl_seconds: 90 * 86_400, action: :delete, subject_field: :id}
               ],
               skip_bag_guard?: true
             )

    assert Enum.any?(violations2, &(&1 =~ "UNREACHED vault-routed transcript"))
  end
  # ======================================================================
  # CLASS (f) — DERIVED-SUMMARY segments (ADR-048 §7.3, batch C4)
  # ======================================================================

  @tag :derived_summary_nonvacuity
  test "NON-VACUITY: the derived_summary class DECLARES what it expects to find — zeroing its scope makes check/1 FAIL, never pass at count 0 (ADR-048 §7.3)" do
    agent_run = Samen.AI.Agent.Run

    # ------------------------------------------------------------------
    # (a) THE CLASS IS NON-EMPTY ON A REAL RESOURCE SET.
    # This half is what a scope-zeroing edit breaks: neuter the ONE traversal the class
    # rides (`discover_transcript/1`) or its projection and this assertion fails, which is
    # the whole point — a guard whose scope is derived from the thing it guards must be
    # unable to be silently zeroed (directive §6).
    # ------------------------------------------------------------------
    residues = Completeness.discover(resources: with_transcript(@clean))

    assert [ds] = residues.derived_summary,
           "the derived_summary class must discover the agent-run fold-ledger surface — " <>
             "an EMPTY enumeration is the vacuity this class exists to refuse"

    assert ds.resource == agent_run
    assert ds.table == "ai_agent_run"
    assert ds.column == "pii_arn_transcript"
    assert ds.index_table == "ai_agent_fold_source"

    # It rides the SAME arm as the transcript class — one traversal, two reported classes.
    assert length(residues.derived_summary) == length(residues.transcript)

    assert {:ok, report} = check(@clean)
    assert report.derived_summary.count == 1
    assert report.derived_summary.columns == ["ai_agent_run.pii_arn_transcript"]
    assert report.derived_summary.arm_wired

    # ------------------------------------------------------------------
    # (b) AT COUNT ZERO THE GATE FAILS CLOSED — it does NOT go green.
    # The other two hard classes are satisfied here on purpose, so the ONLY thing that can
    # produce this error is the new class's own floor. Before C4 this same resource set
    # returned {:ok, _} with `transcript: []` — a class that passes at count zero is not a
    # gate (nodes/C4R/work/nonvacuity.md).
    # ------------------------------------------------------------------
    specs = derived_specs()

    zeroed =
      Completeness.check(
        resources: @clean,
        bidx_specs: specs.blind_index_erasure_specs,
        file_specs: specs.file_erasure_specs,
        skip_bag_guard?: true
      )

    assert zeroed == {:error, {:no_residues_discovered, :derived_summary}},
           "a resource set with NO derived-summary residue must fail closed on the §7.3 " <>
             "floor, never pass at count 0 — got #{inspect(zeroed)}"

    # And the discovery really is empty there (so (b) is failing for the reason claimed,
    # not because some other class collapsed).
    assert Completeness.discover(resources: @clean).derived_summary == []
  end

  @tag :derived_summary_nonvacuity
  test "REFUTABLE: with the §7.3 withdrawal arm UNWIRED the derived-summary residue is named UNREACHED; with it wired it passes (control)" do
    # POSITIVE CONTROL — the live arm (Compaction.withdraw/2 + FoldSource.withdraw_subject/3).
    assert {:ok, report} = check(@clean)
    assert report.derived_summary.arm_wired
    assert report.derived_summary.count == 1

    # RED half: model the arm being deleted. A coverage assertion that cannot fail asserts
    # nothing (the E7 rule), so the class is injectable exactly like the storage_key blob
    # predicate and the object-bag guard.
    assert {:error, {:incomplete, violations, red_report}} =
             check(@clean, derived_summary_arm_fun: fn -> false end)

    refute red_report.derived_summary.arm_wired

    assert Enum.any?(
             violations,
             &(&1 =~ "UNREACHED derived-summary segments" and &1 =~ "pii_arn_transcript" and
                 &1 =~ "ai_agent_fold_source")
           )
  end

  # ======================================================================
  # CLASS (f) APPLICABILITY — the two arms of the C4I4 / Q-01 ruling
  #
  # The §7.3 floor stays HARD; only its SCOPE became explicit. The scope is read from the
  # HOST's configured `:ash_domains` (does this host mount `Samen.AI.Domain` at all), NOT
  # from the transcript attribute the class discovers — a predicate derived from the thing
  # it guards could be silently zeroed by deleting that thing, which is directive §6's
  # defect in its purest form.
  #
  # Arm (a) is the load-bearing one: it proves the predicate is not itself an escape hatch.
  # Mutate `ai_plane_mounted?/1` to always-false and arm (a) MUST fail by name.
  # ======================================================================

  @tag :derived_summary_applicability
  test "ARM (a): a host that DOES mount the AI plane and discovers ZERO derived_summary residues still HARD-FAILS (the applicability predicate is not an escape hatch)" do
    specs = derived_specs()

    # The host mounts the AI plane — declared STRUCTURALLY, from the host domain list,
    # exactly the way driftwood's own `config/config.exs` declares it.
    ai_host = [domains: [Samen.AI.Domain]]

    # ...and this resource set carries NO transcript surface, so the class discovers zero.
    assert Completeness.discover([resources: @clean] ++ ai_host).derived_summary == [],
           "the fixture set must discover zero derived_summary residues for this arm to " <>
             "be measuring the floor at count 0"

    # The other two hard classes are satisfied on purpose, so the ONLY thing that can
    # produce this error is the §7.3 floor itself.
    result =
      Completeness.check(
        [
          resources: @clean,
          bidx_specs: specs.blind_index_erasure_specs,
          file_specs: specs.file_erasure_specs,
          skip_bag_guard?: true
        ] ++ ai_host
      )

    assert result == {:error, {:no_residues_discovered, :derived_summary}},
           "a host that MOUNTS the AI plane and discovers zero derived-summary residues " <>
             "must still HARD-FAIL — scoping the floor to AI-mounting hosts must not turn " <>
             "it into an unguarded escape hatch (nodes/C4R/work/nonvacuity.md STANDS) — " <>
             "got #{inspect(result)}"

    # POSITIVE CONTROL — same predicate, same host, a set that DOES carry the surface
    # passes and is reported APPLICABLE. Without this the arm above could be passing
    # because everything is broken rather than because the floor fired.
    assert {:ok, report} = check(@clean)
    assert report.derived_summary.applicable
    assert report.derived_summary.count == 1
  end

  @tag :derived_summary_applicability
  test "ARM (b): a host that does NOT mount the AI plane passes, with derived_summary REPORTED not-applicable (never a silent skip)" do
    specs = derived_specs()

    # A host whose `:ash_domains` carry no AI plane — demo/pawchart/samen_web and every
    # `mix samen.gen.app`-generated app are exactly this shape.
    assert {:ok, report} =
             Completeness.check(
               resources: @clean,
               domains: [SamenCore.Support.Crm],
               bidx_specs: specs.blind_index_erasure_specs,
               file_specs: specs.file_erasure_specs,
               skip_bag_guard?: true
             )

    assert report.derived_summary.count == 0

    refute report.derived_summary.applicable,
           "the report must carry the class's applicability so the mix task can REPORT the " <>
             "skip — a bare count of 0 cannot tell a reader whether the class was scoped " <>
             "out or silently broken"

    # And the skip is SCOPE, not blindness: the very same resource set on an AI-mounting
    # host fails closed (arm (a)'s property, asserted here as this arm's own control).
    assert {:error, {:no_residues_discovered, :derived_summary}} =
             Completeness.check(
               resources: @clean,
               domains: [Samen.AI.Domain],
               bidx_specs: specs.blind_index_erasure_specs,
               file_specs: specs.file_erasure_specs,
               skip_bag_guard?: true
             )
  end
end
