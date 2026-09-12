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

  alias Samen.AI.Agent.FoldSource
  alias Samen.AI.Agent.Ingress
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Secrets
  alias Samen.AI.Chokepoint
  alias Samen.AI.Completion

  require Ash.Query

  # ADR-048 §7.3 — the WITHDRAWAL WALK's hard round bound. The walk is a FIXPOINT over ONE
  # run's finite fold ledger, so the fixpoint alone already terminates: every round either
  # adds at least one fold number to the withdrawn set or stops, and the set can never grow
  # past the ledger's own size. The bound is the SECOND, structural guarantee — a fold that
  # cites ITSELF (`seq == n`), or a pair of folds that cite each other, must not be able to
  # spin this loop even if a later edit breaks the fixpoint reasoning. BOUNDED is a
  # requirement here, not an adjective: `agent_withdrawal_walk_test.exs`'s cyclic arm
  # asserts it by name.
  @withdraw_max_rounds 64

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

  @doc """
  Build ONE ADR-048 §7.3 fold-ledger source marker: `{resource, record_id, subject_ref}`.

  Token-only by construction — a marker carries an opaque resource name, an opaque record
  id and a `subject_ref`, and never a value. This is the constructor the Level-1 fold uses
  when it records WHERE a folded span came from, and it is the ONE site that decides how a
  citation is keyed.

  Fails closed: a subject whose pseudonym cannot be read yields
  `{:error, {:pseudonym_unavailable, reason}}` and no marker at all. A fold that cannot
  say whose data it cites must not claim a citation it cannot later withdraw.
  """
  @spec source_marker(module() | String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, {:pseudonym_unavailable, term()}}
  def source_marker(resource, record_id, subject_id)
      when is_binary(record_id) and is_binary(subject_id) do
    case source_ref(subject_id) do
      {:ok, ref} ->
        {:ok,
         %{
           "resource" => to_string(resource),
           "record_id" => record_id,
           "subject_ref" => ref
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hex-encode an already-computed pseudonym into the ledger/index `subject_ref` token.

  The SAME encoding `source_ref/1` applies, exposed separately for the ONE caller that
  must compute the pseudonym itself: `Samen.Erasure`, which reads it from the LIVE DEK
  before `Samen.Kms.shred/1` destroys the key (after that it is uncomputable forever) and
  needs the `:absent` / `:shredded` / outage classification that `source_ref/1` collapses.
  Kept beside `source_ref/1` so the two can never disagree about what a ref looks like;
  `agent_fold_source_test.exs` asserts they agree.
  """
  @spec encode_ref(binary()) :: String.t()
  def encode_ref(pseudonym) when is_binary(pseudonym),
    do: Base.encode16(pseudonym, case: :lower)

  @doc """
  ADR-048 §7.3 step 3 — the BOUNDED WITHDRAWAL WALK. NEUTRALIZE every derived-summary
  segment that descends from the erased subject, in every run that cites them.

  Called from `Samen.Erasure`'s steps-2–5 `Ecto.Multi` with the hex `subject_ref` the
  caller captured from the LIVE DEK **before** `Samen.Kms.shred/1` destroyed it (ADR-046's
  envelope is untouched: key destruction still runs FIRST and OUTSIDE the transaction).

  ## Why this is a WALK and not a filter

  A fold summary is derived text. A LATER fold can fold the earlier fold's summary — so a
  segment can descend from the subject without ever carrying a marker naming them. §7.3
  therefore withdraws the TRANSITIVE CLOSURE inside each run's ledger: the folds citing the
  subject directly, plus every fold citing one of those, to a fixpoint.

  ## Why it is BOUNDED

  Two independent guarantees, because a cycle in derived provenance is a real shape and a
  walk that loops on it is an erasure job that never completes:

    1. the closure is a fixpoint over a FINITE ledger — each round adds ≥ 1 fold number or
       halts, and the set is capped by the ledger's own length; a self-citing fold
       (`seq == n`) adds nothing it does not already contain;
    2. a hard `@withdraw_max_rounds` cap that halts with `halted: :round_bound` regardless.

  ## Why targets come from the INDEX, never from a transcript scan

  `Samen.AI.Agent.FoldSource` is keyed on the pseudonym, so the walk resolves WHICH runs to
  open without decrypting anything, and it opens only those. Cross-run citation is NOT
  followed: ADR-048 D3 refuses compaction output crossing a run boundary at WRITE time
  (§8 `P12`), so a cross-run parent is a defect to refuse, never a link to traverse.

  NEUTRALIZES — it never deletes. The marker is fixed, bounded and uniform
  (`"[withdrawn: fold #N, source withdrawn]"`), so the transform is many-to-one and carries
  no residual signal about what stood there. The fold's token-only provenance markers are
  KEPT: after the shred the pseudonym is uncomputable forever, so they are permanently
  unlinkable, and dropping them would erase the evidence that a withdrawal happened.

  Returns a report; `:absent`-shaped hosts (no AI plane mounted) walk zero runs.
  """
  @spec withdraw(String.t(), keyword()) :: %{
          runs_walked: non_neg_integer(),
          folds_withdrawn: non_neg_integer(),
          rounds: non_neg_integer(),
          halted: :fixpoint | :round_bound
        }
  def withdraw(subject_ref, opts \\ []) when is_binary(subject_ref) do
    repo = Keyword.get(opts, :repo) || AshPostgres.DataLayer.Info.repo(Run, :mutate)
    max_rounds = Keyword.get(opts, :max_rounds, @withdraw_max_rounds)

    subject_ref
    |> FoldSource.run_ids_citing(repo)
    |> Enum.reduce(
      %{runs_walked: 0, folds_withdrawn: 0, rounds: 0, halted: :fixpoint},
      fn run_id, acc ->
        {withdrawn, rounds, halted} = withdraw_run(run_id, subject_ref, repo, max_rounds)

        %{
          runs_walked: acc.runs_walked + 1,
          folds_withdrawn: acc.folds_withdrawn + withdrawn,
          rounds: acc.rounds + rounds,
          halted: if(halted == :round_bound, do: :round_bound, else: acc.halted)
        }
      end
    )
  end

  @doc """
  ADR-048 §7.3 step 5 — does this run hold a fold whose SOURCE was withdrawn?

  Read from the pseudonym-keyed index, so the turn boundary answers it without decrypting
  the transcript. `Samen.AI.Agent`'s loop calls this at every turn boundary and terminates
  the run fail-honest with the bounded kind `:source_withdrawn`: a run that keeps executing
  on a neutralized context is the defect D6 exists to make impossible.
  """
  @spec source_withdrawn?(Run.t() | %{id: String.t()}) :: boolean()
  def source_withdrawn?(%{id: run_id}) when is_binary(run_id) do
    FoldSource.withdrawn?(run_id, AshPostgres.DataLayer.Info.repo(Run, :mutate))
  end

  def source_withdrawn?(_run), do: false

  # ---------------------------------------------------------------------------
  # The walk, one run at a time
  # ---------------------------------------------------------------------------

  defp withdraw_run(run_id, subject_ref, repo, max_rounds) do
    case load_ledger(run_id, repo) do
      {:ok, run, decoded, folds} ->
        {targets, rounds, halted} = withdrawal_closure(run_id, folds, subject_ref, max_rounds)

        if MapSet.size(targets) == 0 do
          {0, rounds, halted}
        else
          neutralized = Enum.map(folds, &neutralize(&1, targets))
          persist_ledger!(run, Map.put(decoded, "folds", neutralized))
          {MapSet.size(targets), rounds, halted}
        end

      :error ->
        {0, 0, :fixpoint}
    end
  end

  # The TRANSITIVE CLOSURE, bounded twice over (see `withdraw/2`'s "Why it is BOUNDED").
  defp withdrawal_closure(run_id, folds, subject_ref, max_rounds) do
    seed =
      for %{"n" => n} = fold <- folds,
          is_integer(n),
          cites_subject?(fold, subject_ref),
          into: MapSet.new(),
          do: n

    expand(run_id, folds, seed, 0, max_rounds)
  end

  defp expand(_run_id, _folds, acc, rounds, max_rounds) when rounds >= max_rounds,
    do: {acc, rounds, :round_bound}

  defp expand(run_id, folds, acc, rounds, max_rounds) do
    next =
      for %{"n" => n} = fold <- folds,
          is_integer(n),
          not MapSet.member?(acc, n),
          cites_withdrawn_fold?(fold, run_id, acc),
          into: acc,
          do: n

    if MapSet.equal?(next, acc) do
      {acc, rounds, :fixpoint}
    else
      expand(run_id, folds, next, rounds + 1, max_rounds)
    end
  end

  defp cites_subject?(fold, subject_ref) do
    fold
    |> markers()
    |> Enum.any?(&(Map.get(&1, "subject_ref") == subject_ref))
  end

  # SAME-RUN citation only — D3 refuses a cross-run parent at write time (§8 `P12`), so a
  # ledger carrying one is a defect for that gate to name, never a link this walk follows.
  defp cites_withdrawn_fold?(fold, run_id, acc) do
    fold
    |> Map.get("sources", [])
    |> List.wrap()
    |> Enum.any?(fn source ->
      Map.get(source, "run_id") == run_id and MapSet.member?(acc, Map.get(source, "seq"))
    end)
  end

  defp markers(fold) do
    fold
    |> Map.get("sources", [])
    |> List.wrap()
    |> Enum.flat_map(fn source -> source |> Map.get("markers", []) |> List.wrap() end)
  end

  # §7.3 step 3: replace the SUMMARY, keep everything else — the entry, its number, and its
  # token-only provenance all survive, because the record that a withdrawal happened is
  # itself part of the honest answer.
  defp neutralize(%{"n" => n} = fold, targets) do
    if MapSet.member?(targets, n) do
      Map.put(fold, "summary", withdrawn_marker(n))
    else
      fold
    end
  end

  defp neutralize(fold, _targets), do: fold

  @doc """
  The ADR-048 §7.3 step-3 neutralizing marker — FIXED, bounded and uniform, so the
  transform is many-to-one and leaks nothing about the segment it replaced.
  """
  @spec withdrawn_marker(integer()) :: String.t()
  def withdrawn_marker(n) when is_integer(n), do: "[withdrawn: fold ##{n}, source withdrawn]"

  defp load_ledger(run_id, repo) do
    with {:ok, [run]} <-
           Run
           |> Ash.Query.filter(id == ^run_id)
           |> Ash.Query.ensure_selected([:org_id, :transcript])
           |> Ash.Query.limit(1)
           |> Ash.read(authorize?: false),
         %Samen.Masked{} = masked <- run.transcript,
         {:ok, json} <- Samen.Vault.reveal(masked, repo, subject_id: run.id),
         {:ok, %{} = decoded} <- Jason.decode(json),
         folds when is_list(folds) <- Map.get(decoded, "folds", []) do
      {:ok, run, decoded, folds}
    else
      _ -> :error
    end
  end

  defp persist_ledger!(run, decoded) do
    run
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(decoded)})
    |> Ash.update!(authorize?: false)
  end

  # ADR-048 §7.3 — the provenance index lives OUTSIDE the sealed body, so the
  # walk never decrypts a transcript to find its own targets. `subject_ref` is
  # therefore the DEK-KEYED PSEUDONYM, never the subject id: after the shred the
  # key is gone and every remaining row is permanently unlinkable.
  defp source_ref(subject_id) do
    case Samen.Vault.pseudonym(subject_id) do
      {:ok, pseudonym} -> {:ok, Base.encode16(pseudonym, case: :lower)}
      {:error, reason} -> {:error, {:pseudonym_unavailable, reason}}
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
