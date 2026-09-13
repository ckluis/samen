defmodule C3I2SummaryAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c3i2.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentSummaryIngressTest do
  @moduledoc """
  ADR-048 batch C3 (`T219`), node `C3I2` — the two properties of §5's ingress path that
  `C3R`'s `P1`/`P9` arms do **not** discriminate on their own:

    * **THE ORDER IS LOAD-BEARING (§5#3 / T184).** `P1`'s two neutralization arms are
      satisfied by EITHER order: a contiguous vendor-prefixed key is redacted whether
      `Ingress.sanitize/1` ran before or after, and an injected instruction is neutralized
      either way. This file's ORDER arm carries the input the two orders DISAGREE on — a
      labeled secret whose value is separated from its label by an invisible control
      character. `Secrets.redact/1` first collapses the whole `label + gap + value` span to
      one marker; `Ingress.sanitize/1` first replaces the control character with its own
      marker, whose 11 letters then break the adjacency the labeled fallback matches on,
      and the credential survives in CLEARTEXT. Swapping the two lanes therefore flips this
      arm by name, which is what makes ADR-048's stated order a rule rather than a comment.

    * **FAILING OPEN IS THE DEFECT THIS BATCH EXISTS TO MAKE IMPOSSIBLE (§5#5).** On a
      refusal — `{:error, :pii_egress_refused}` from the chokepoint, or a `safe_segment?/1`
      failure on the returned summary — **the fold does not happen and the run continues
      UNCOMPACTED.** Not: append the summary anyway. Not: terminate the run. Three
      separately-named arms below pin exactly that, each with the anti-vacuity control that
      the SAME run shape WITH a clean summary really does fold (otherwise "no fold happened"
      would pass against a build with no compactor at all).

  ## Driving one call and not the others

  `Samen.AI.Provider.Scripted` serves entries strictly in order, one per `complete/2`, and
  §5#1 adds one summarizer call per folding turn — so WHICH index the summarizer lands on is
  an implementation detail no test should pin (`C3R`'s reasoning, adopted). Every entry here
  is therefore the SAME zero-arity fun, and the fun decides from the payload it is currently
  answering: `Scripted` records the payload BEFORE it consumes the entry, so
  `Scripted.sent_payloads/0`'s head is this call's own payload, and a segment carrying
  `Samen.AI.Agent.summarizer_prompt/0` (§5#2's compile-time literal, public for exactly this
  kind of assertion) identifies the summarize call without pinning an ordinal.

  Positive controls for this file's hit-count sweep, taken at the same HEAD:
  `safe_segment?` = 26, `max_turns` = 39
  (`_orch-runs/adr048-c1-c4-20260907/nodes/C3I2/work/counts.txt`).
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias C3I2SummaryAgents.Durable
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Ingress
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Secrets
  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo

  require Ash.Query

  # An ordinary assistant turn: `FINAL:`-free (the run must end on `max_turns`, the
  # deterministic terminal), and free of every scrub trigger so it can never be mistaken for
  # a neutralized summary.
  @turn_text "checked the carrier manifest and the depot log"

  # ORDINARY SUMMARY PROSE — the positive control every arm reads off the SAME summary.
  @prose "the depot received seventeen crates on Tuesday"

  # THE ORDER DISCRIMINATOR. `Secrets`' generic labeled fallback matches
  # `label + [^\\p{L}\\p{N}]* + value`; U+200B (a `\\p{Cf}` format character) is inside that
  # non-language gap, so redacting FIRST collapses the whole span. `Ingress.sanitize/1`
  # replaces U+200B with `[neutralized]`, and `neutralized` is ELEVEN letters — one short of
  # the fallback's 12-character value floor and, more decisively, letters, which end the gap.
  # Sanitizing first therefore leaves `password:[neutralized]<value>` in cleartext.
  @labeled_value "supersecretvalue123456"
  @order_summary "Summary: " <>
                   @prose <>
                   ". The rotation note said password:" <>
                   <<0x200B::utf8>> <> @labeled_value <> " was retired."

  # A summary carrying a vault FK token — the `safe_segment?/1` failure of §5#5. Neither
  # scrub lane recognizes it (it is neither vendor-shaped nor label-adjacent nor
  # instruction-shaped), so it reaches the chokepoint allowlist intact and REFUSES there.
  @vt_summary "Summary: " <> @prose <> ", filed against " <> "vt_" <> "deadbeefcafe0123."

  # The clean summary the anti-vacuity controls use: same shape, nothing to refuse.
  @clean_summary "Summary: " <> @prose <> "."

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

  defp new_scope do
    org_id = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp folds_of(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    {:ok, json} = Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
    Map.get(Jason.decode!(json), "folds", [])
  end

  # Is the call being answered right now the §5#1 SUMMARIZE call? Asked of the payload, never
  # of a call ordinal (see the moduledoc).
  defp summarizer_call? do
    case Scripted.sent_payloads() do
      [{:complete, payload} | _] ->
        payload.segments
        |> List.flatten()
        |> Enum.any?(fn seg ->
          is_binary(seg) and String.contains?(seg, Agent.summarizer_prompt())
        end)

      _ ->
        false
    end
  end

  # Four turns under a 1-token watermark: turns 3 and 4 each try to fold, so every arm runs
  # against a run that really reached the fold path. `answer` decides what the SUMMARIZER
  # gets; every other call is an ordinary turn.
  defp fold_run!(answer) do
    s = new_scope()

    script(
      for _ <- 1..24,
          do: fn -> if summarizer_call?(), do: answer, else: {:continue, @turn_text} end
    )

    result =
      run_scripted(Durable, s, "goal CANARY-c3i2-summary",
        budgets: [max_turns: 4, context_cutoff_tokens: 1]
      )

    run = assert_honest_exhaustion!(result)
    run = reload(run)
    assert {:ok, views} = Agent.transcript_views(run)
    {run, views, folds_of(run)}
  end

  # THE ANTI-VACUITY FLOOR every refusal arm stands on: the identical run shape, with the
  # ONLY difference being that the summarizer does not refuse, DOES fold. Without it,
  # "no fold happened" would pass against a build that never folds at all.
  defp assert_folds_when_clean! do
    {_run, views, folds} = fold_run!({:continue, @clean_summary})

    assert folds != [],
           "the control run did not fold either, so this arm's `folds == []` says nothing " <>
             "about the refusal — it says the compactor is missing"

    assert Enum.any?(views.llm_view, &String.contains?(&1, @prose)),
           "the control run folded but its summary is not in the persisted llm_view"

    :ok
  end

  defp refusal_notes(run) do
    run
    |> turn_rows()
    |> Enum.map(fn row -> inspect(row.meta) end)
  end

  # ======================================================================
  # THE ORDER — `Secrets.redact/1` THEN `Ingress.sanitize/1` (ADR-048 §5#3 / T184)
  # ======================================================================

  test "C3I2: ORDER — Secrets.redact/1 runs BEFORE Ingress.sanitize/1 on the summary path: a LABELED SECRET whose value is separated from its label by an invisible control character is REDACTED in the persisted llm_view (sanitize-first leaves it in cleartext)" do
    {_run, views, folds} = fold_run!({:continue, @order_summary})

    assert folds != [],
           "no fold ran at all, so there is no persisted summary for the order to be a " <>
             "property of — the anti-vacuity floor, applied here"

    summary = hd(folds)["body"]

    assert summary in views.llm_view,
           "the summary segment is not in the persisted llm_view (§5#3 appends it there)"

    # THE DISCRIMINATION. Redact-first collapses `password:<U+200B><value>` to one marker.
    # Sanitize-first turns U+200B into `[neutralized]`, which breaks the label/value
    # adjacency, and the credential survives — so THIS refutation is the order's.
    refute summary =~ @labeled_value,
           "the labeled credential survived into the persisted summary " <>
             "(#{inspect(summary)}) — the two ingress lanes ran in the WRONG ORDER: " <>
             "`Ingress.sanitize/1` inserted its marker between the label and the value " <>
             "before `Secrets.redact/1` ever saw them, which is precisely why ADR-048 " <>
             "§5#3 pins the secrets lane FIRST, on the untouched raw binary"

    assert summary =~ Secrets.marker(),
           "the credential is absent but carries no `#{Secrets.marker()}` — it was deleted " <>
             "or never arrived. The refutation must be a REDACTION, not an absence."

    # POSITIVE CONTROL, on the SAME `summary` binding (never variable-disjoint): a build
    # that answers the arm above by deleting the summary fails HERE.
    assert summary =~ @prose,
           "ordinary summary prose did not survive the ingress path (#{inspect(summary)}) " <>
             "— §5#3 scrubs; it does not censor"

    assert String.contains?(summary, "Summary: " <> @prose <> ".")
  end

  # ======================================================================
  # FAIL-CLOSED — the fold does not happen, and the run continues (ADR-048 §5#5)
  # ======================================================================

  test "C3I2: FAIL-CLOSED — on {:error, :pii_egress_refused} from the summarize call THE FOLD DOES NOT HAPPEN: no ledger entry, no marker, and no summary segment in the persisted llm_view" do
    :ok = assert_folds_when_clean!()

    {run, views, folds} = fold_run!({:error, :pii_egress_refused})

    assert folds == [],
           "a refused summarize still produced a fold ledger entry (#{inspect(folds)}) — " <>
             "the fold DID happen, which is the fail-OPEN reading ADR-048 §5#5 forbids"

    refute Enum.any?(views.llm_view, &String.contains?(&1, "[folded")),
           "the llm_view carries a fold marker after a refused summarize: the span was " <>
             "dropped and replaced anyway"

    refute Enum.any?(views.ui_view, &String.contains?(&1, "[fold #")),
           "the ui_view claims a fold that was refused"

    # The refusal is OBSERVABLE and NAMED (§5#5's bounded `:compaction_refused`), so an
    # uncompacted run is never indistinguishable from a run that never needed to fold.
    notes = refusal_notes(run)

    assert Enum.any?(notes, &String.contains?(&1, "compaction_refused")),
           "no turn row records the bounded `:compaction_refused` note, so the refusal is " <>
             "silent — a refusal nobody can see is indistinguishable from a fold that was " <>
             "never attempted (turn metas: #{inspect(notes)})"

    assert Enum.any?(notes, &String.contains?(&1, "pii_egress_refused")),
           "the note does not say WHICH refusal this was (turn metas: #{inspect(notes)})"
  end

  test "C3I2: FAIL-CLOSED — on {:error, :pii_egress_refused} THE RUN CONTINUES UNCOMPACTED: it takes every remaining turn and ends on its own max_turns budget, never on the refusal" do
    :ok = assert_folds_when_clean!()

    {run, views, _folds} = fold_run!({:error, :pii_egress_refused})

    # `assert_honest_exhaustion!/1` (inside `fold_run!/1`) already refused any `{:ok, …}`
    # promotion; this is the OTHER half — the refusal did not terminate the run either.
    assert run.error_kind == "max_turns",
           "the run ended on #{inspect(run.error_kind)}, not on its own budget — a refused " <>
             "COMPACTION terminated the RUN. §5#5 says the run continues uncompacted; " <>
             "terminating is as wrong as folding anyway, in the other direction"

    assert run.current_turn == 4,
           "the run stopped at turn #{run.current_turn} of 4: it did not continue past the " <>
             "refused fold"

    assert length(turn_rows(run)) == 4

    # UNCOMPACTED, literally: every turn's own line is still there, none folded away.
    assert Enum.count(views.llm_view, &String.contains?(&1, @turn_text)) == 4,
           "the persisted llm_view carries #{inspect(views.llm_view)} — a refused fold must " <>
             "leave the history it could not summarize exactly as it found it"
  end

  test "C3I2: FAIL-CLOSED — a summary that fails safe_segment?/1 (it carries a vt_ vault token) is REFUSED the same way: the fold does not happen, the token never reaches the transcript, and the run continues uncompacted" do
    :ok = assert_folds_when_clean!()

    {run, views, folds} = fold_run!({:continue, @vt_summary})

    assert folds == [],
           "a summary the chokepoint allowlist refuses was folded in anyway " <>
             "(#{inspect(folds)}) — `safe_segment?/1` did not gate the segment BEFORE the " <>
             "append, so a `vt_` token reached the governed transcript and would only have " <>
             "refused on its RE-ENTRY, after it was already at rest"

    refute Enum.any?(views.llm_view, &String.contains?(&1, "vt_")),
           "a `vt_` token is in the persisted llm_view (INV-7)"

    refute Enum.any?(views.ui_view, &String.contains?(&1, "vt_")),
           "a `vt_` token is in the persisted ui_view (INV-7)"

    assert_no_text_at_rest!(run, ["vt_" <> "deadbeefcafe0123"])

    # ...and the run CONTINUED, exactly as on the chokepoint refusal.
    assert run.error_kind == "max_turns"
    assert run.current_turn == 4

    notes = refusal_notes(run)

    assert Enum.any?(notes, &String.contains?(&1, "compaction_refused")),
           "the allowlist refusal left no bounded note (turn metas: #{inspect(notes)})"

    assert Enum.any?(notes, &String.contains?(&1, "unsafe_summary")),
           "the note does not distinguish an allowlist refusal from a chokepoint one " <>
             "(turn metas: #{inspect(notes)})"
  end

  # ======================================================================
  # The transform itself — asserted directly, so the order and the gate are refutable
  # without a provider round-trip (ADR-048 §5#3)
  # ======================================================================

  test "C3I2: Compaction.scrub/1 — redact-then-sanitize, then the allowlist: markers are DISTINCT, prose is byte-intact, a vt_-bearing summary REFUSES, and a summary ingress empties REFUSES" do
    assert Secrets.marker() != Ingress.marker()

    {:ok, scrubbed} = Samen.AI.Agent.Compaction.scrub(@order_summary)

    assert scrubbed == @order_summary |> Secrets.redact() |> Ingress.sanitize(),
           "scrub/1 is not exactly the shipped `Secrets.redact() |> Ingress.sanitize()` chain"

    refute scrubbed == @order_summary |> Ingress.sanitize() |> Secrets.redact(),
           "the two orders agree on this input, so this arm cannot discriminate them — " <>
             "the discriminator itself has been weakened"

    assert String.contains?(scrubbed, "Summary: " <> @prose <> ".")
    refute scrubbed =~ @labeled_value

    assert {:error, :unsafe_summary} = Samen.AI.Agent.Compaction.scrub(@vt_summary)
    assert {:error, :empty_summary} = Samen.AI.Agent.Compaction.scrub("   ")
  end
end
