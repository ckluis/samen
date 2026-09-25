defmodule Samen.AI.AiPromptMaskingProvenanceTest do
  @moduledoc """
  ADR-048 §5 / §8 P10 — CF-21: the PROVENANCE half of the `ai_prompt_masking` red-team,
  split out of `Samen.AI.AiPromptMaskingRedTeamTest` (issue #13).

  ## Why this is its own module, and why it is `async: false`

  These two arms script `Samen.AI.Provider.Scripted`, whose script AND recording live in
  `:persistent_term` — deliberately: `scripted.ex` documents it as *"cross-process, the A2
  worker seam"*, because A2's `Samen.AI.Agent.TurnWorker` runs turns in whatever process
  runs the job (an Oban drain, a watchdog replay, a spawned crash-simulation Task) and a
  process-local script would answer `{:error, :not_configured}` for work that WAS scripted.
  The price of that seam, stated in the same moduledoc, is that `Scripted` is a
  **ONE-RUNNER-AT-A-TIME** double: "agent suites run `async: false` and `reset/0` in setup".

  `ai_prompt_masking_test.exs` is `async: true` and its other ~30 arms have every right to
  be — they observe `Provider.Fake`, which records per-process. Only these two arms touch
  the global double, and they were the single `async: true` module out of the 19 that touch
  `Scripted`: no race today, a trap armed for the next author. So the arms moved here rather
  than the whole file going sync, and rather than `Scripted` going process-scoped — option 3
  in issue #13, which would break the seam for the 18 sync agent suites that need it.

  `samen_core/test/meta/scripted_async_isolation_test.exs` now enforces the class, so the
  trap cannot be re-armed silently.

  Every assertion below is byte-identical to the arms as they stood in
  `ai_prompt_masking_test.exs`; only the enclosing module changed.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.Provider

  # ADR-048 §8 P10 / CF-21 — a summarizer that calls NO provider and FABRICATES its own text
  # leaves both P10 egress arms in `ai_prompt_masking_test.exs` GREEN: neither asserts
  # PROVENANCE, only the canary's absence. `@p10_reply_marker` is the ONE shared binding the
  # provenance arm below and its positive control BOTH assert PRESENT in the persisted summary — true of that summary ONLY
  # because `Samen.AI.Agent.Compaction.summarize/3` actually dispatched to a provider and the
  # provider's own reply (never an invented string) flowed back through `scrub/1` unmangled.
  @p10_reply_marker "P10-PROVENANCE-REPLY-4d8b2f19"
  # A distinctive token planted in the folded span handed to `summarize/3`, read back off
  # `Provider.Scripted.sent_payloads/0` — proof the provider call actually carried the fold's
  # OWN content rather than being skipped entirely.
  @p10_fold_marker "P10-FOLD-CONTENT-7a61c4e0"

  # --------------------------------------------------------------------------------------
  # ADR-048 §5 / §8 P10 — CF-21: PROVENANCE, not merely the canary's absence.
  #
  # The two P10 egress arms in `ai_prompt_masking_test.exs` assert only that a fixed canary
  # literal is absent from what the
  # provider was sent / what the summary contains. A summarizer that calls NO provider at
  # all and FABRICATES its own summary text satisfies both vacuously — there is no canary to
  # leak because there was never a real call. These two arms close that: they run the
  # PRODUCTION seam (`Samen.AI.Agent.Compaction.summarize/3` — exactly what
  # `Samen.AI.Agent`'s private `summarize_span/3` calls, ADR-048 §5#1), script
  # `Provider.Scripted` with a distinctive reply, and assert (a) the provider was actually
  # invoked carrying the fold's own content (`Provider.Scripted.sent_payloads/0`) and (b) the
  # persisted summary carries the text the provider actually returned — never an invented one.
  # --------------------------------------------------------------------------------------

  @tag :p10
  test "P10: the compaction summarizer's persisted summary is provenanced to an actual provider reply, not fabricated (CF-21)" do
    Provider.Scripted.reset()
    Provider.Scripted.script([{:continue, "Summary: " <> @p10_reply_marker}])

    folded = ["turn 1: the customer opened a ticket", "turn 2: " <> @p10_fold_marker]

    assert {:ok, summary} =
             Samen.AI.Agent.Compaction.summarize(
               %{plane: :tenant},
               folded,
               provider: {Provider.Scripted, %{}},
               grounding: %{}
             )

    sent_segments =
      Provider.Scripted.sent_payloads()
      |> Enum.flat_map(fn {_callback, payload} -> payload.segments end)

    assert Enum.any?(sent_segments, fn seg -> is_binary(seg) and seg =~ @p10_fold_marker end),
           "P10: summarize/3 never handed the folded span's own content to the provider — " <>
             "a fabricator that calls no provider at all would still pass without this " <>
             "assertion (CF-21)"

    assert summary =~ @p10_reply_marker,
           "P10: the persisted summary does not carry the provider's actual reply text — a " <>
             "fabricator invents its own text, and only this assertion catches it (CF-21)"
  end

  @tag :p10
  test "P10: control — a genuine provider-backed compaction summary carries the provider's own reply (CF-21 anti-tautology)" do
    Provider.Scripted.reset()
    Provider.Scripted.script([{:continue, "Summary: " <> @p10_reply_marker}])

    folded = ["turn 1: a routine status update, nothing sensitive"]

    assert {:ok, summary} =
             Samen.AI.Agent.Compaction.summarize(
               %{plane: :tenant},
               folded,
               provider: {Provider.Scripted, %{}},
               grounding: %{}
             )

    assert summary =~ @p10_reply_marker,
           "P10 control: the plain happy path must ALSO show the provider's reply text " <>
             "present in the persisted summary — the shared assertion the mutation proof " <>
             "flips together with the arm above"
  end
end
