defmodule Samen.BreakGlass.Reconciliation do
  @moduledoc """
  Anchor the locally-durable break-glass audit into the central T4.3 chain when the
  control plane returns (T4.4 clause (b); doc "honest edges" break-glass bullet:
  *"When the control plane returns, those entries are anchored into the WORM chain
  (and reconciled into aud_event); the chain detects any gap or tamper because each
  local entry carries the prior hash"*).

  ## What reconciliation does

    1. **Verify the local chain first** (`LocalAudit.verify_chain/1`). If the local
       file has been tampered with (a hand-edited line, a deleted middle entry, a
       gap), reconciliation REFUSES `{:error, {:local_tamper, detail}}` and anchors
       NOTHING — a corrupted local record is not silently laundered into the central
       chain. This is the local→central seam's tamper detection.
    2. **Anchor each not-yet-anchored local entry** into the central chain via
       `Samen.AuditChain.Writer.write/2` (which writes the `aud_event` row AND the
       linked `aud_chain` entry in the same connection). Each central entry records
       the local `correlation_id`, `subject_id`, `actor_id`, and a `detail` that
       marks it as a deferred break-glass anchor and carries the local `seq`.
    3. **Track what has been anchored** in `brc_break_glass_anchor` (abbrev `brc_`),
       keyed by the local entry's content hash, so reconciliation is IDEMPOTENT — a
       second run does not double-anchor, and a partial run resumes.

  ## Gap detection across the seam

  The local chain is dense from seq 0. `reconcile/1` anchors entries in seq order
  and records the highest anchored seq. If, on a later run, the local file's seq 0
  is MISSING (the file was rotated/truncated without reconciliation) while the
  anchor table shows entries were previously anchored past that point, the local
  verify fails (`:seq_gap`) — surfaced, not swallowed. A local entry whose content
  hash is unknown to the anchor table but whose seq is BELOW an already-anchored
  seq (a back-dated insertion) is detected because the local chain's `verify_chain/1`
  would already have rejected the re-hashed links.

  ## Configuration

      config :samen_core, :break_glass_anchor_repo, MyApp.Repo  # falls back to suspension repo
  """

  alias Samen.BreakGlass.{LocalAudit, AnchorRow}
  alias Samen.AuditChain

  import Ecto.Query, only: [from: 2]

  @doc "The repo backing the anchor-tracking table."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :break_glass_anchor_repo) ||
      Samen.OperatorPlane.Suspension.repo()
  end

  @doc """
  Reconcile the local break-glass audit into the central chain.

  Options:
    * `:repo` — the central-chain repo (defaults to the anchor repo)
    * `:path` — the local audit file (defaults to `LocalAudit.path/0`)

  Returns:
    * `{:ok, %{anchored: n, already: m, total: t}}` — verified + anchored;
    * `{:error, {:local_tamper, {reason, seq}}}` — the local chain is corrupt;
      NOTHING is anchored (fail closed across the seam);
    * `{:error, term}` — the central chain / repo was unreachable (fail closed;
      the entries stay local, telemetry keeps firing).
  """
  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term}
  def reconcile(opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    path = Keyword.get(opts, :path, LocalAudit.path())

    # 1. Verify the local chain BEFORE anchoring anything. A tampered local record
    #    is refused, not laundered into the central chain.
    case LocalAudit.verify_chain(path: path) do
      {:error, {reason, seq}} ->
        {:error, {:local_tamper, {reason, seq}}}

      {:ok, _summary} ->
        with {:ok, entries} <- LocalAudit.entries(path: path) do
          anchor_entries(r, entries)
        end
    end
  end

  defp anchor_entries(r, entries) do
    Enum.reduce_while(entries, {:ok, %{anchored: 0, already: 0, total: length(entries)}}, fn
      entry, {:ok, acc} ->
        cond do
          already_anchored?(r, entry.hash) ->
            {:cont, {:ok, %{acc | already: acc.already + 1}}}

          true ->
            case anchor_one(r, entry) do
              :ok -> {:cont, {:ok, %{acc | anchored: acc.anchored + 1}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
    end)
  end

  # Anchor a single local entry into the central chain + record the anchor row.
  # Both writes ride ONE transaction so an anchored central entry and its tracking
  # row commit atomically (no double-anchor, no orphan tracking).
  defp anchor_one(r, entry) do
    result =
      r.transaction(fn ->
        write_result =
          AuditChain.Writer.write(r, %{
            org_id: entry.org_id,
            event_type: "break_glass",
            subject_id: entry.subject_id,
            actor_id: entry.actor_id,
            correlation_id: entry.correlation_id,
            detail:
              "event=break_glass_reveal deferred-anchor local_seq=#{entry.seq} " <>
                "reason=#{entry.reason}",
            occurred_at: parse_dt(entry.occurred_at)
          })

        case write_result do
          {:ok, _} ->
            r.insert!(
              %AnchorRow{}
              |> Ecto.Changeset.cast(
                %{
                  local_hash: entry.hash,
                  local_seq: entry.seq,
                  org_id: entry.org_id,
                  subject_id: entry.subject_id,
                  actor_id: entry.actor_id,
                  correlation_id: entry.correlation_id,
                  anchored_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
                },
                [
                  :local_hash,
                  :local_seq,
                  :org_id,
                  :subject_id,
                  :actor_id,
                  :correlation_id,
                  :anchored_at
                ]
              )
            )

            :anchored

          {:error, reason} ->
            r.rollback(reason)
        end
      end)

    case result do
      {:ok, :anchored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp already_anchored?(r, local_hash) do
    r.exists?(from(a in AnchorRow, where: a.local_hash == ^local_hash))
  rescue
    _ -> false
  end

  # ==========================================================================
  # Unanchored monitoring (R8) — the telemetry signal
  # ==========================================================================

  @doc """
  How many local break-glass entries are NOT yet anchored into the central chain.

  Computed as `local_count - anchored_count` (both cheap). A positive value means
  the honest residue window is open (entries live only on the operator node's disk).
  """
  @spec unanchored_count(keyword()) :: non_neg_integer()
  def unanchored_count(opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    path = Keyword.get(opts, :path, LocalAudit.path())

    local = LocalAudit.count(path: path)
    anchored = anchored_count(r)
    max(local - anchored, 0)
  end

  defp anchored_count(r) do
    r.one(from(a in AnchorRow, select: count(a.id))) || 0
  rescue
    _ -> 0
  end

  @doc """
  Emit the `[:samen, :break_glass, :unanchored]` telemetry signal when unanchored
  local entries exist (R8 monitoring). Returns the count. A monitoring cron / the
  operator dashboard calls this; the signal firing is the alert that the residue
  window is open and reconciliation should run.

  Always emits (count may be 0) so a downstream can also observe "back to zero"
  after a successful reconcile; the `:unanchored` measurement is the load-bearing
  value.
  """
  @spec emit_unanchored_signal(keyword()) :: non_neg_integer()
  def emit_unanchored_signal(opts \\ []) do
    count = unanchored_count(opts)

    :telemetry.execute(
      [:samen, :break_glass, :unanchored],
      %{count: count},
      %{path: Keyword.get(opts, :path, LocalAudit.path())}
    )

    count
  end

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_dt(_), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
