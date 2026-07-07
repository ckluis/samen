defmodule Samen.BreakGlass.LocalAudit do
  @moduledoc """
  The **locally-durable, append-only, hash-chained** break-glass audit record on
  the operator node's own disk (T4.4; doc "honest edges" break-glass bullet:
  *"an append-only, hash-chained record on the operator node's own disk (fsync'd,
  not the central DB) that captures who/what/why before the reveal is granted …
  the chain detects any gap or tamper because each local entry carries the prior
  hash"*).

  ## What this is (and is NOT)

  This is the DEGRADED-MODE audit sink for `Samen.BreakGlass`: when the central
  control-plane / `aud_chain` DB is unreachable, an emergency reveal STILL has to
  be accountable. So the who/what/why is written HERE — to a local file on the
  operator node — BEFORE the reveal is granted (never after). Each entry carries
  the prior entry's hash, so the file is a self-contained hash chain that
  `verify_chain/1` can check for edits, deletes, and gaps.

  It is a faithful analogue of `Samen.Anchor.LocalWorm` (same fsync + verify-on-read
  discipline) but with two differences that matter:

    * it is a **hash CHAIN** (each line links to the prior), not independent sealed
      heads — because a break-glass session may write several entries before the
      control plane returns, and the chain's ordering/completeness is the
      accountability claim;
    * it stores the **full who/what/why payload** (still token-only — subject id,
      operator id, reason, resource/action), so a reconciliation into the T4.3
      chain has the material to rebuild the central entry.

  ## Durability discipline (the R8 residue is about the disk, not this code)

    * opened `[:append]` — never rewound, never overwrites a prior line;
    * `:file.datasync/1` (fsync) on EVERY append — a crash after `append/2`
      returns leaves the entry durable;
    * verify-on-read — each line embeds `SHA256(canonical(entry))`; a truncated or
      hand-edited line is REJECTED on read (it does not silently become a trusted
      entry) AND surfaces as a chain error.

  The honest residue (doc): between the local write and the reconciliation there
  is a window where the audit lives only on this node's disk. If the node's disk
  does not survive, that entry is lost. R8's design decision (persistent-volume
  mount vs accept-and-monitor) is recorded in the T4.4 report + runbook, and the
  `[:samen, :break_glass, :unanchored]` telemetry fires while such entries exist.

  ## Storage line format

      <content_hash> <base64(canonical_json)>

  where `content_hash = SHA256(canonical_json(entry))` and `canonical_json` is the
  deterministic encoder from `Samen.AuditChain.Canonical` (sorted keys, explicit
  nulls) — the SAME canonicalizer the central chain uses, so a local entry and its
  reconciled central entry hash identically over the same fields.

  ## Path

  Configure with `config :samen_core, :break_glass_local_audit_path, "/…"`.
  Defaults to `Path.join(System.tmp_dir!(), "samen_break_glass.local")`. Production
  points this at a persistent volume (see the runbook). Tests set a per-test path.
  """

  alias Samen.AuditChain.Canonical

  @genesis_preimage "samen/break-glass/local-audit/genesis/v1"

  @typedoc """
  A local break-glass entry. `seq`/`prior_hash`/`hash` are the chain fields; the
  rest is the who/what/why payload (token-only). `anchored?` is NOT stored in the
  file — it is derived by the reconciler comparing against the central chain.
  """
  @type entry :: %{
          seq: non_neg_integer(),
          prior_hash: String.t(),
          hash: String.t(),
          org_id: String.t(),
          subject_id: String.t(),
          actor_id: String.t(),
          reason: String.t(),
          resource: String.t() | nil,
          action: String.t() | nil,
          correlation_id: String.t(),
          occurred_at: String.t()
        }

  @doc "The genesis prior_hash of the first local entry (seq 0)."
  @spec genesis() :: String.t()
  def genesis, do: :crypto.hash(:sha256, @genesis_preimage) |> Base.encode16(case: :lower)

  @doc """
  Append a who/what/why entry to the local hash chain. fsync'd before it returns.

  `attrs` (all token-only): `:org_id`, `:subject_id`, `:actor_id`, `:reason`,
  optionally `:resource`, `:action`, `:correlation_id`, `:occurred_at`.

  Computes `seq`/`prior_hash`/`hash` from the current tail of the file (read fresh
  each time — the file IS the state). Returns `{:ok, entry}` or `{:error, term}`.

  This is called BEFORE the reveal is granted (`Samen.BreakGlass`). A failure to
  write here MUST fail the whole break-glass attempt closed (can't log it ⇒ can't
  see it), which is the caller's responsibility.
  """
  @spec append(map(), keyword()) :: {:ok, entry()} | {:error, term}
  def append(attrs, opts \\ []) do
    file = Keyword.get(opts, :path, path())

    with {:ok, tail} <- read_chain(file) do
      {seq, prior_hash} =
        case List.last(tail) do
          nil -> {0, genesis()}
          %{seq: s, hash: h} -> {s + 1, h}
        end

      payload = payload(attrs, seq, prior_hash)
      hash = Canonical.hash(prior_hash, payload)
      entry = Map.put(payload, :hash, hash)

      case append_line(file, encode_line(entry)) do
        :ok -> {:ok, entry}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The canonical, deterministic payload that both the local hash AND (later) the
  # reconciled central chain commit to. `prior_hash` is included so a lifted-and-
  # reinserted line from a different position cannot verify.
  defp payload(attrs, seq, prior_hash) do
    %{
      seq: seq,
      prior_hash: prior_hash,
      org_id: to_string(get(attrs, :org_id) || Samen.AuditChain.global_org()),
      subject_id: to_string(fetch!(attrs, :subject_id)),
      actor_id: to_string(fetch!(attrs, :actor_id)),
      reason: to_string(fetch!(attrs, :reason)),
      resource: opt_str(get(attrs, :resource)),
      action: opt_str(get(attrs, :action)),
      correlation_id:
        to_string(get(attrs, :correlation_id) || Ecto.UUID.generate()),
      occurred_at: iso(get(attrs, :occurred_at))
    }
  end

  @doc """
  Read + verify the whole local chain. Returns `{:ok, %{entries: [entry], head_seq,
  head_hash, count}}` when the chain is intact, or `{:error, {reason, seq}}` on the
  first inconsistency (`:tampered_line`, `:seq_gap`, `:broken_link`, `:hash_mismatch`).

  An empty / absent file verifies `{:ok, %{count: 0, …}}` — nothing to tamper.
  """
  @spec verify_chain(keyword()) :: {:ok, map()} | {:error, {atom(), non_neg_integer()}}
  def verify_chain(opts \\ []) do
    file = Keyword.get(opts, :path, path())

    with {:ok, entries} <- read_chain_strict(file) do
      verify_entries(entries)
    end
  end

  @doc """
  All entries in the file, in chain order, WITHOUT verifying the links (but each
  line's own content hash IS checked — a tampered line still raises `:tampered_line`).
  Used by the reconciler after `verify_chain/1` has already confirmed integrity.
  """
  @spec entries(keyword()) :: {:ok, [entry()]} | {:error, term}
  def entries(opts \\ []) do
    read_chain_strict(Keyword.get(opts, :path, path()))
  end

  @doc "Number of entries currently on disk (does not verify links)."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    case read_chain(Keyword.get(opts, :path, path())) do
      {:ok, es} -> length(es)
      _ -> 0
    end
  end

  # ==========================================================================
  # verify_entries — the link/gap/hash checks (mirrors Samen.AuditChain.do_verify)
  # ==========================================================================

  defp verify_entries(entries) do
    do_verify(entries, 0, genesis())
  end

  defp do_verify([], expected_seq, prior_hash) do
    head_seq = if expected_seq == 0, do: -1, else: expected_seq - 1

    {:ok,
     %{
       count: expected_seq,
       head_seq: head_seq,
       head_hash: if(expected_seq == 0, do: genesis(), else: prior_hash),
       entries: []
     }}
  end

  defp do_verify([entry | rest], expected_seq, prior_hash) do
    cond do
      entry.seq != expected_seq ->
        {:error, {:seq_gap, expected_seq}}

      entry.prior_hash != prior_hash ->
        {:error, {:broken_link, entry.seq}}

      true ->
        recomputed = Canonical.hash(entry.prior_hash, Map.delete(entry, :hash))

        if recomputed != entry.hash do
          {:error, {:hash_mismatch, entry.seq}}
        else
          do_verify(rest, expected_seq + 1, entry.hash)
        end
    end
  end

  # ==========================================================================
  # File I/O — append-only + fsync + verify-on-read
  # ==========================================================================

  defp append_line(file, line) do
    with :ok <- ensure_dir(Path.dirname(file)),
         {:ok, io} <- :file.open(file, [:append, :binary, :raw]) do
      try do
        with :ok <- :file.write(io, line),
             # fsync — the durability the deferred-anchor break-glass relies on.
             :ok <- :file.datasync(io) do
          :ok
        end
      after
        :file.close(io)
      end
    end
  end

  # Create the directory, returning {:error, reason} instead of raising — a failure
  # here MUST fail the break-glass closed (can't log it ⇒ can't see it), not crash
  # the caller with an unhandled exception.
  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Lenient read for append (skips a trailing torn/tampered line rather than
  # refusing the whole append — append still links off the last VALID entry, and
  # verify_chain/1 will report the bad line). Returns {:ok, [entry]}.
  defp read_chain(file) do
    case File.read(file) do
      {:ok, contents} ->
        {:ok,
         contents
         |> String.split("\n", trim: true)
         |> Enum.flat_map(&decode_lenient/1)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Strict read for verify/reconcile: a tampered line is a HARD error (a break-glass
  # audit whose line hash does not match is a tamper we must surface, not skip).
  defp read_chain_strict(file) do
    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> reduce_strict()

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce_strict(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case decode_strict(line) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp decode_lenient(line) do
    case decode_strict(line) do
      {:ok, entry} -> [entry]
      {:error, _} -> []
    end
  end

  # A valid line is "<content_hash> <base64(canonical_json)>" where
  # content_hash == SHA256(canonical_json). Any mismatch → tamper.
  defp decode_strict(line) do
    case String.split(line, " ", parts: 2) do
      [stored_hash, payload_b64] ->
        with {:ok, canonical} <- Base.decode64(payload_b64),
             {:ok, map} <- decode_canonical(canonical) do
          if content_hash(canonical) == stored_hash do
            {:ok, map}
          else
            {:error, {:tampered_line, Map.get(map, :seq, -1)}}
          end
        else
          _ -> {:error, {:tampered_line, -1}}
        end

      _ ->
        {:error, {:tampered_line, -1}}
    end
  end

  # The canonical JSON we write is produced by Samen.AuditChain.Canonical.encode/1
  # (deterministic). We DON'T re-parse it with a JSON lib (that would drop the
  # ordering contract); instead we store the ORIGINAL entry map alongside as the
  # value we re-encode. To keep the file self-describing we encode the entry map's
  # canonical JSON as the payload AND decode it back with Jason for the field values
  # (field VALUES are order-independent; the content-hash guards the exact bytes).
  defp decode_canonical(canonical) do
    case Jason.decode(canonical) do
      {:ok, raw} ->
        {:ok,
         %{
           seq: raw["seq"],
           prior_hash: raw["prior_hash"],
           hash: raw["hash"],
           org_id: raw["org_id"],
           subject_id: raw["subject_id"],
           actor_id: raw["actor_id"],
           reason: raw["reason"],
           resource: raw["resource"],
           action: raw["action"],
           correlation_id: raw["correlation_id"],
           occurred_at: raw["occurred_at"]
         }}

      _ ->
        :error
    end
  end

  defp encode_line(entry) do
    canonical = Canonical.encode(entry)
    ch = content_hash(canonical)
    ch <> " " <> Base.encode64(canonical) <> "\n"
  end

  defp content_hash(canonical) when is_binary(canonical) do
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @doc "The configured local audit file path."
  @spec path() :: String.t()
  def path do
    Application.get_env(:samen_core, :break_glass_local_audit_path) ||
      Path.join(System.tmp_dir!(), "samen_break_glass.local")
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp opt_str(nil), do: nil
  defp opt_str(v), do: to_string(v)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.truncate(dt, :microsecond))
  defp iso(_), do: DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :microsecond))

  defp fetch!(attrs, key) do
    case get(attrs, key) do
      nil -> raise ArgumentError, "Samen.BreakGlass.LocalAudit: missing required #{inspect(key)}"
      v -> v
    end
  end
end
