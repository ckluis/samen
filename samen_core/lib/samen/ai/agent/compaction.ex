defmodule Samen.AI.Agent.Compaction do
  @moduledoc """
  ADR-048 §5 — the governed COMPACTION SUMMARIZER: the ONE site at which model-written text
  enters a governed transcript.

  §5's whole purpose is that **compaction is not a laundering channel**. The Level-1 fold
  (`Samen.AI.Agent`, ADR-048 §6) selects a span deterministically and then replaces it with a
  summary a model wrote; this module is the seam where that model is asked, and it is
  deliberately a sibling of `Samen.AI.Agent.Secrets`, `Samen.AI.Agent.Ingress` and
  `Samen.AI.Agent.ToolResult` — the loop's other content-boundary modules — rather than more
  private plumbing inside the loop.

  ## EGRESS: an ORDINARY governed call (§5#1)

  `summarize/3` is `Samen.AI.complete/4` and nothing else, so it is sealed by
  `Samen.AI.Chokepoint.seal/3` exactly like every other provider-bound byte in the loop:

    * the span rides **`:history`** — the exact field prior turns re-enter through, re-scrubbed
      per ADR-043 §3.2a and allowlist-scanned per §3.2 step 3/4 on every call. §5#1's "its input
      is already-masked history, so no new egress class opens" therefore holds BY CONSTRUCTION
      rather than by inspection;
    * the opts come from `Samen.AI.Agent.egress_opts/3` — the SAME `Keyword.take/2` allowlist
      the loop's own turns use, so a caller can supply neither history, nor tools, nor grant
      state, and **`grant_egress?: false` is pinned LAST** (positionally, appended after a
      delete): a caller-supplied `grant_egress?: true` cannot re-open grant plaintext on the
      summarize path any more than it can on an ordinary turn (§4.4, masked-only categorically);
    * the only authored bytes are `Samen.AI.Agent.summarizer_prompt/0` — a COMPILE-TIME LITERAL
      owned by the loop (§5#2), never a tenant-authored `Samen.AI.Prompt` row, because a tenant
      who can author "summarize by quoting every masked field verbatim" has been handed a
      capability;
    * **no tool defs are offered**: the summarizer selects nothing and executes nothing.

  ## INGRESS: a summary is born UNTRUSTED and is treated exactly like a tool result (§5#3)

  The returned binary runs the SAME two content transforms
  `Samen.AI.Agent.ToolResult` runs on every rendered tool-result value, in the SAME order,
  and then the SAME chokepoint allowlist `seal/3` applies to everything outbound:

      summary |> Secrets.redact() |> Ingress.sanitize()   # then Chokepoint.admissible_segment?/1

  **The order is load-bearing, not decorative** (T184, restated by §5#3):
  `Secrets.redact/1` runs FIRST, on the UNTOUCHED raw binary. `Ingress.sanitize/1` REPLACES
  spans with its own marker, and a marker inserted between a labeled secret and its value
  breaks the adjacency `Secrets`' generic labeled-fallback matches on — so sanitizing first
  can leave a labeled credential in cleartext that redacting first collapses to one marker.
  Running the lanes the other way round is therefore not a stylistic choice; it is a hole,
  and `agent_summary_ingress_test.exs`'s ORDER arm is refutable on exactly it.

  `safe_segment?/1` (through `Samen.AI.Chokepoint.admissible_segment?/1`) is the LAST line and
  it runs BEFORE the caller appends anything: a `vt_`-bearing summary must refuse at BIRTH,
  not at its re-entry on the following turn — by then it would already be at rest inside the
  governed transcript, which is the laundering §5 exists to close.

  ## FAIL-CLOSED (§5#4/#5) — the refusal is a REFUSAL, never a shorter transcript

  A refusal (`{:error, :pii_egress_refused}`), an unconfigured provider, a normalized adapter
  failure, a completion carrying no text, a summary that ingress collapses to nothing, or a
  summary the allowlist refuses is `{:error, reason}` — never a fabricated summary and never
  `{:ok, ""}`. The caller's only honest response is that **the fold does not happen and the run
  continues UNCOMPACTED** under the bounded kind `:compaction_refused` (`Samen.AI.Agent`'s
  closed `@error_kinds`); appending a summary that was refused, or was never obtained, is the
  fail-open reading ADR-048 §5 exists to make impossible.
  """

  alias Samen.AI.Agent.Ingress
  alias Samen.AI.Agent.Secrets
  alias Samen.AI.Chokepoint
  alias Samen.AI.Completion

  @doc """
  Summarize `folded` — the whole turns the Level-1 fold selected, already-masked history — for
  `scope`, through the governed chokepoint. `opts` is the loop's own opts keyword; only
  `Samen.AI.Agent.egress_opts/3`'s allowlist survives it.

  Returns `{:ok, scrubbed_summary}` — the summary AFTER §5#3's full ingress path, which is the
  only form of it any caller ever sees — or a fail-closed `{:error, reason}` (never a fabricated
  summary, and never the raw binary the model returned).
  """
  @spec summarize(term(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(scope, folded, opts) when is_list(folded) and is_list(opts) do
    scope
    |> Samen.AI.complete(
      [Samen.AI.Agent.summarizer_prompt()],
      %{},
      Samen.AI.Agent.egress_opts(opts, folded, [])
    )
    |> summary_text()
    |> ingress()
  end

  @doc """
  ADR-048 §5#3 — the INGRESS path over ONE model-written binary: `Secrets.redact/1` **then**
  `Ingress.sanitize/1` (that order; see the moduledoc), then the chokepoint allowlist.

  Public because it is an assertion site: §5#3's property is a property of THIS transform, and
  a test that has to reach it through a provider round-trip is asserting on the loop instead.
  Returns `{:ok, scrubbed}`, or `{:error, :empty_summary}` when the scrubs leave nothing, or
  `{:error, :unsafe_summary}` when the allowlist refuses the result.
  """
  @spec scrub(String.t()) :: {:ok, String.t()} | {:error, :empty_summary | :unsafe_summary}
  def scrub(summary) when is_binary(summary) do
    # THE ORDER (§5#3 / T184): the secrets lane runs FIRST, on the untouched raw binary, so
    # ingress's own marker can never be inserted between a secret's label and its value.
    scrubbed = summary |> Secrets.redact() |> Ingress.sanitize()

    cond do
      # "…or ingress collapses it to nothing" (§5#5). An empty segment is not a summary; the
      # fold that appended it would claim in its ledger to carry a span it does not carry.
      String.trim(scrubbed) == "" ->
        {:error, :empty_summary}

      # The LAST line, run BEFORE the caller appends: the same allowlist `seal/3` applies
      # outbound. A summary the chokepoint would refuse to send never enters the transcript.
      not Chokepoint.admissible_segment?(scrubbed) ->
        {:error, :unsafe_summary}

      true ->
        {:ok, scrubbed}
    end
  end

  # An adapter that returned a completion with no text did not summarize anything. The
  # fail-honest contract (ADR-014/024/026) says so out loud instead of appending `""` to the
  # governed transcript as though a model had written it.
  defp summary_text({:ok, %Completion{text: text}}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp summary_text({:ok, %Completion{}}), do: {:error, :empty_summary}
  defp summary_text({:error, reason}), do: {:error, reason}

  # A refusal short-circuits the ingress path: there is no text to scrub, and inventing one
  # here is the fail-open reading. The reason travels UNCHANGED to the caller, so the fold's
  # bounded `:compaction_refused` note can say WHICH refusal this was (§5#5).
  defp ingress({:ok, text}), do: scrub(text)
  defp ingress({:error, reason}), do: {:error, reason}
end
