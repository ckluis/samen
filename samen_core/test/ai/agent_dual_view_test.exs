defmodule C1RTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c1r.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end

  # C1I2C — drives the PARK/pending-approval path (`encode_transcript/3`), the SECOND
  # write call site named by `nodes/C1V/work/seats/coverage-truth-2.verdict.md`. A write
  # tool always proposes-then-parks (ADR-047 §5.3) — no config knob involved — so
  # declaring a write tool here is the whole trigger.
  defmodule WriteAgent do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c1i2c.write",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      tools: ["assign_record_owner"]
  end
end

defmodule Samen.AI.AgentDualViewTest do
  @moduledoc """
  ADR-048 batch C1 (`T217`) — RED-FIRST tests for the dual-view transcript, written
  against the UNBUILT feature (llm_view/ui_view/folds are ADR-048 §4 forward
  references — zero `grep -rn` hits in the repo at the time this file was written).

  This file implements NOTHING under `samen_core/lib`. Each test below is expected
  to FAIL today, by name, at the first assertion that the dual-view keys exist in the
  persisted transcript JSON. Once C1I1/C1I2 land the one-blob three-field shape, the
  remainder of each test body becomes the real gate:

    * P2  (ADR-048 §8) — compaction never rewrites `ui_view`. A TEST-ONLY fold driver
      mutates `llm_view` through the SAME `:advance` persistence path the real
      compactor will use (C1 ships no compactor); `ui_view` bytes must stay
      unchanged.
    * P11 (ADR-048 §8, D2) — one blob, two keys, one DEK. Shredding the run's single
      DEK must render BOTH views unreadable in ONE operation, and the live schema
      must carry exactly one physical transcript column/table (never two, each with
      its own retention spec). Ships with its MANDATORY positive control: a run with
      no fold yet still has both views present and readable before the shred.
    * E7  (ADR-048 §9) — `discover_transcript/1` (reached only via the public
      `Completeness.discover/1`, since it is `defp`) must stay byte-identical to the
      pre-C1 baseline captured in `nodes/C1R/work/e7-baseline.txt`.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias C1RTestAgents.{Durable, WriteAgent}
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Provider.Scripted
  alias Samen.Erasure
  alias Samen.Erasure.Completeness
  alias SamenCore.Support.AutomationFixture.Target
  alias SamenCore.TestRepo

  require Ash.Query

  # C1I2C — the fixed resource-key string the `assign_record_owner` tool's `validate/2`
  # expects for its `"resource"` argument (same shape as `agent_write_test.exs`'s
  # `@target_key`, kept local so this file drives the park path without depending on a
  # module defined in a different test file that is not always compiled alongside it).
  @park_target_key "SamenCore.Support.AutomationFixture.Target"

  # The pre-C1 baseline captured at HEAD eb0966d981239e1758087b2f2be32b8a66ad6d7e,
  # branch chore/close-outstanding-todos (nodes/C1R/work/e7-baseline.txt). C1's
  # reader-side-only migration adds no new pii_attribute / physical column, so this
  # exact shape must still be what `Completeness.discover/1` reports post-C1.
  @e7_baseline [
    %{table: "ai_agent_run", column: "pii_arn_transcript", vault: :pii_transcript}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Breaker.reset()
    end)

    :ok
  end

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp new_scope, do: scope(Ash.UUID.generate())

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp reveal_transcript(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
  end

  # C1I2C — drives `encode_transcript/3` (the park/pending-approval call site): propose a
  # write tool call and stop at `:awaiting_approval`. No approval is ever granted — this
  # node only needs the PARK write, never the approved execution.
  defp park_a_run! do
    s = new_scope()

    target =
      Target
      |> Ash.Changeset.for_create(:create, %{
        org_id: s.actor.org_id,
        title: "C1I2C park target",
        priority: :high,
        email: "canary-c1i2c-park@leak.example"
      })
      |> Ash.create!(authorize?: false)

    script([
      {:tool_call, "assign_record_owner",
       %{"resource" => @park_target_key, "id" => target.id, "user_id" => Ash.UUID.generate()}},
      {:final, "assigned (should never be reached before approval)"}
    ])

    assert {:awaiting_approval, run} =
             run_scripted(WriteAgent, s, "who should own this record?")

    run
  end

  # ======================================================================
  # P2 — compaction never rewrites the UI view (ADR-048 §8 `:495`)
  # ======================================================================

  test "P2: RED — compaction never rewrites ui_view; a TEST-ONLY fold driver mutates llm_view through the same :advance persistence path and ui_view bytes must stay unchanged" do
    s = new_scope()
    script(final: "the CANARY-p2 answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p2")

    assert {:ok, json_before} = reveal_transcript(run)
    decoded_before = Jason.decode!(json_before)

    # THE RED: the dual view does not exist yet (ADR-048 §4 forward reference) — there
    # is no ui_view for this test to prove unmutated. C1 ships no compactor, so this
    # is the test-only fold driver's own precondition, not the compactor's.
    assert Map.has_key?(decoded_before, "ui_view"),
           "ADR-048 §4 dual-view transcript not yet built — ui_view key absent from " <>
             "the persisted transcript, so P2 has nothing to prove unmutated yet"

    ui_view_before = decoded_before["ui_view"]

    # TEST-ONLY fold driver (never a compactor, never an :after_compaction call site):
    # persist a mutated llm_view through the SAME accepted `:advance` path the real
    # compactor will use to write a fold.
    run_row = reload(run)
    folded = Map.put(decoded_before, "llm_view", "FOLDED-SUMMARY-p2")

    run_row
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(folded)})
    |> Ash.update!(authorize?: false)

    assert {:ok, json_after} = reveal_transcript(run)
    decoded_after = Jason.decode!(json_after)

    assert decoded_after["ui_view"] == ui_view_before,
           "compaction (even the test-only driver) rewrote ui_view — P2 violated"
  end

  # ======================================================================
  # C1I2 — reader-side-only migration: a legacy `lines`-only blob (no `ui_view`,
  # no `llm_view`, no `folds`) is exactly what an in-flight pre-C1 run has on disk.
  # No backfill and no sealed-byte rewrite ever runs, so `Samen.AI.Agent.transcript_views/1`
  # alone must serve both views from `lines` when the new keys are absent.
  # ======================================================================

  test "P2 READER MIGRATION: a transcript blob containing only the legacy lines key reads back with both ui_view and llm_view populated from it" do
    s = new_scope()
    script(final: "the CANARY-p2-legacy answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p2-legacy")

    # Overwrite the sealed blob with the PRE-C1 shape: only "goal" and "lines", no
    # dual-view keys at all — the same `:advance` persistence path P2 uses above,
    # simulating a run whose transcript predates this batch entirely.
    assert {:ok, json_before} = reveal_transcript(run)
    legacy_only = Jason.decode!(json_before) |> Map.take(["goal", "lines"])
    refute Map.has_key?(legacy_only, "ui_view")
    refute Map.has_key?(legacy_only, "llm_view")

    run
    |> reload()
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(legacy_only)})
    |> Ash.update!(authorize?: false)

    reloaded = reload(run)

    assert {:ok, %{ui_view: ui_view, llm_view: llm_view}} =
             Samen.AI.Agent.transcript_views(reloaded),
           "the reader must serve both views from a legacy lines-only blob, not error"

    assert ui_view == legacy_only["lines"],
           "ui_view must fall back to the legacy lines key when its own key is absent"

    assert llm_view == legacy_only["lines"],
           "llm_view must fall back to the legacy lines key when its own key is absent"
  end

  # ======================================================================
  # coverage-truth closure (nodes/C1V/work/seats/coverage-truth.verdict.md) — two of
  # C1's dual-view promises were checked for PRESENCE only, never VALUE, so a build
  # that silently fakes `folds`' or a fresh run's `ui_view`'s content passed all 5
  # pre-existing tests. These two assertions close that: both are VALUE checks
  # against a run encoded through the real `encode_transcript/2,3` path — never a
  # hand-built legacy blob.
  # ======================================================================

  test "FOLDS CONTENT: a freshly-created run's folds ledger equals the empty ledger, not merely present" do
    s = new_scope()
    script(final: "the CANARY-folds-content answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-folds-content")

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    assert Map.has_key?(decoded, "folds"),
           "ADR-048 §4 folds ledger not yet built — folds key absent"

    assert decoded["folds"] == [],
           "a freshly-created run must ship an EMPTY folds ledger by VALUE — coverage-truth " <>
             "proved that checking only Map.has_key?(decoded, \"folds\") lets a build silently " <>
             "populate a fake fold entry undetected"
  end

  test "UI VIEW CONTENT: a normally-created run's ui_view equals its transcript lines, encoded through encode_transcript" do
    s = new_scope()
    script(final: "the CANARY-ui-view-content answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-ui-view-content")

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    assert Map.has_key?(decoded, "ui_view"),
           "ADR-048 §4 dual-view transcript not yet built — ui_view absent"

    assert decoded["ui_view"] == decoded["lines"],
           "ui_view must equal the run's own transcript lines for a NORMALLY-created run (through " <>
             "encode_transcript, never a hand-built legacy blob) — coverage-truth proved that no " <>
             "test in this file asserted ui_view's content on that path, so a value unrelated to " <>
             "the real transcript passed undetected"
  end

  # ======================================================================
  # coverage-truth SECOND PASS (nodes/C1V/work/seats/coverage-truth-2.verdict.md) —
  # `encode_transcript/3`, used ONLY by the park/pending-approval path, performs its own
  # identical `ui_view`/`folds` writes. The two tests above drive ONLY the 2-arity
  # `encode_transcript/2` path (a plain scripted final answer never parks), so they never
  # exercise this second call site. These two pin it, through a REAL write-tool proposal
  # (`park_a_run!/0`), never a hand-built blob.
  # ======================================================================

  test "PARK UI VIEW CONTENT: the park path's ui_view equals its transcript lines, encoded through encode_transcript/3" do
    run = park_a_run!()

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    assert Map.has_key?(decoded, "ui_view"),
           "ADR-048 §4 dual-view transcript not yet built on the PARK path — ui_view absent"

    assert decoded["ui_view"] == decoded["lines"],
           "ui_view must equal the run's own transcript lines for a PARKED run (through " <>
             "encode_transcript/3, the pending-approval call site) — coverage-truth's second " <>
             "pass proved this call site's own ui_view write is untested repo-wide"
  end

  test "PARK FOLDS CONTENT: the park path's folds ledger equals the empty ledger, not merely present" do
    run = park_a_run!()

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    assert Map.has_key?(decoded, "folds"),
           "ADR-048 §4 folds ledger not yet built on the PARK path — folds key absent"

    assert decoded["folds"] == [],
           "a freshly-parked run must ship an EMPTY folds ledger by VALUE through " <>
             "encode_transcript/3 (the pending-approval call site) — coverage-truth's second " <>
             "pass proved this call site's own folds write is untested repo-wide"
  end

  # ======================================================================
  # P11 — D2: one blob, two keys, one DEK (ADR-048 §8 `:497`, `:500`-adjacent)
  # ======================================================================

  test "P11 POSITIVE CONTROL: an unfolded run's transcript carries BOTH ui_view and llm_view, readable before any shred" do
    s = new_scope()
    script(final: "the CANARY-p11-control answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p11-control")

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    # THE RED: neither view exists yet — the positive control's own precondition
    # (both views present pre-shred, with NO fold having happened) is unmet.
    assert Map.has_key?(decoded, "ui_view"),
           "ADR-048 §4 dual-view transcript not yet built — ui_view absent even " <>
             "before any fold"

    assert Map.has_key?(decoded, "llm_view"),
           "ADR-048 §4 dual-view transcript not yet built — llm_view absent even " <>
             "before any fold"

    assert decoded["ui_view"] not in [nil, ""], "ui_view must be present AND readable"
    assert decoded["llm_view"] not in [nil, ""], "llm_view must be present AND readable"
  end

  test "P11: RED — shredding the run's single DEK renders BOTH ui_view and llm_view unreadable in ONE operation (D2: one blob, two keys, one DEK)" do
    s = new_scope()
    script(final: "the CANARY-p11 answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p11")

    # Positive-control precondition, inline: both views must exist and be readable
    # pre-shred (the mandatory anti-tautology half — a run with no fold yet still has
    # both views).
    assert {:ok, json_before} = reveal_transcript(run)
    decoded_before = Jason.decode!(json_before)

    assert Map.has_key?(decoded_before, "ui_view"),
           "ADR-048 §4 dual-view transcript not yet built — ui_view absent"

    assert Map.has_key?(decoded_before, "llm_view"),
           "ADR-048 §4 dual-view transcript not yet built — llm_view absent"

    assert {:ok, %{attestation: %{state: :shredded}}} =
             Erasure.shred(run.id, repo: TestRepo, org_id: s.actor.org_id)

    # ONE shred operation renders BOTH views unreadable — never two tables with two
    # independent retention specs, each needing its own shred (D2/P11; not P2, which
    # only tests that ui_view is not mutated by a fold).
    assert {:error, :shredded} = reveal_transcript(run)

    # Schema-level: exactly one persisted transcript column/table carries BOTH views.
    # A build that split llm_view/ui_view into two pii_attributes (two physical
    # columns) would still pass the reveal-fails check above while violating D2
    # outright — this assertion is what catches that split.
    actual =
      Completeness.discover(resources: [Run]).transcript
      |> Enum.map(&Map.take(&1, [:table, :column, :vault]))

    assert actual == @e7_baseline,
           "the transcript must live in exactly ONE physical column/table — a " <>
             "two-table split (two retention specs) violates D2 even if shred " <>
             "still (coincidentally) reaches both"
  end

  # ======================================================================
  # E7 — discover_transcript/1 re-runs byte-identical (ADR-048 §9)
  # ======================================================================

  test "E7: RED — discover_transcript/1 must stay byte-identical to the pre-C1 baseline once the dual-view transcript lands (ADR-048 §9)" do
    s = new_scope()
    script(final: "the CANARY-e7 answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-e7")

    assert {:ok, json} = reveal_transcript(run)
    decoded = Jason.decode!(json)

    # THE RED: the dual-view forward references do not exist yet.
    assert Map.has_key?(decoded, "llm_view"),
           "ADR-048 §4 llm_view not yet built"

    assert Map.has_key?(decoded, "ui_view"),
           "ADR-048 §4 ui_view not yet built"

    assert Map.has_key?(decoded, "folds"),
           "ADR-048 §4 folds ledger not yet built"

    # Once it exists: discover_transcript/1 (private; reached only via the public
    # Completeness.discover/1) must report EXACTLY the pre-C1 baseline shape — one
    # resource, one physical column, one vault. The reader-side-only migration adds
    # no new persisted column/table.
    actual =
      Completeness.discover(resources: [Run]).transcript
      |> Enum.map(&Map.take(&1, [:table, :column, :vault]))

    assert actual == @e7_baseline
  end
end
