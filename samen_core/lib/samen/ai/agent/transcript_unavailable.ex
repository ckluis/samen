defmodule Samen.AI.Agent.TranscriptUnavailable do
  @moduledoc """
  Raised inside `Samen.AI.Agent` when a transcript WRITE cannot carry the prior views forward because the vault read of
  them failed. It aborts the write (and the transaction around it) so the stored transcript is left untouched; the turn
  loop, `execute_approved/3` and `reject_proposal/3` rescue it and answer `:transcript_unavailable`. The message is a
  fixed word: the failure itself is reported by name through `Samen.Observability.Failure` before this is raised.
  """
  defexception message: "transcript_unavailable"
end
