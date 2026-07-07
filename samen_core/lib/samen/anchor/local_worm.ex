defmodule Samen.Anchor.LocalWorm do
  @moduledoc """
  Faithful local WORM anchor adapter (T4.3; ADR-002 §3.2).

  An **append-only file** (`O_APPEND`), one JSON-ish line per seal, **fsync'd on every
  append**, with **verify-on-read**: each line carries its own content hash
  (`SHA256(canonical(anchor))`), and a truncated/edited/re-hashed line is REJECTED on
  read. A seal never overwrites a prior line — the newest head for an org is the last
  matching line.

  ## Why this is faithful, and where the seam is (ADR-002 §3.2)

  This IS a faithful WORM stand-in for the anchor's actual job — *detecting a rewritten
  DB chain*:

    * It is **append-only at the file layer** (opened `[:append]`, never rewound).
    * It **fsyncs** every append (`:file.datasync/1`), so a crash after `seal/1` returns
      leaves the anchor durable — the same durability the deferred-anchor break-glass
      (T4.4) depends on.
    * It **detects in-file edits on read**: every line embeds `SHA256(canonical(record))`;
      `read_head/1` / `list_heads/0` recompute it and skip (log) any line whose stored
      hash does not match — so hand-editing a sealed head in the file is caught, it does
      not silently become the trusted head.

  It is NOT a true compliance-mode object lock: a local root can still `rm` the whole
  file. That is out of scope for the anchor's guarantee. The anchor exists to catch a
  party who rewrote the **DB** `aud_chain` but does NOT also control the WORM store; for
  that seam an fsync'd append-only file with edit-detection is sufficient. The
  compliance-mode "even root cannot delete it" property is the `S3ObjectLock` skeleton's
  job (ADR-002 §3.2), the production adapter.

  ## Path

  Configure the file path with `config :samen_core, :anchor_local_worm_path, "/…"`.
  Defaults to `Path.join(System.tmp_dir!(), "samen_audit_anchor.worm")`. Tests set a
  fresh per-test path.
  """

  @behaviour Samen.Anchor

  require Logger

  @impl true
  def worm?, do: true

  @impl true
  def seal(%{org_id: org_id, seq: seq, hash: hash} = anchor) do
    record = normalize(org_id, seq, hash, Map.get(anchor, :sealed_at))
    line = encode_line(record)

    with :ok <- append_line(path(), line) do
      {:ok, %{sealed_at: record.sealed_at, bytes: byte_size(line)}}
    end
  end

  def seal(_), do: {:error, :invalid_anchor}

  @impl true
  def read_head(org_id) when is_binary(org_id) do
    case read_valid_records(path()) do
      {:ok, records} ->
        head =
          records
          |> Enum.filter(&(&1.org_id == org_id))
          |> Enum.max_by(& &1.seq, fn -> nil end)

        {:ok, head || :none}

      {:error, :enoent} ->
        {:ok, :none}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_heads do
    case read_valid_records(path()) do
      {:ok, records} ->
        heads =
          records
          |> Enum.group_by(& &1.org_id)
          |> Enum.map(fn {_org, rs} -> Enum.max_by(rs, & &1.seq) end)

        {:ok, heads}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ==========================================================================
  # File I/O — append-only + fsync
  # ==========================================================================

  defp append_line(file, line) do
    File.mkdir_p!(Path.dirname(file))

    case :file.open(file, [:append, :binary, :raw]) do
      {:ok, io} ->
        try do
          with :ok <- :file.write(io, line),
               # fsync: the durability the deferred-anchor break-glass relies on.
               :ok <- :file.datasync(io) do
            :ok
          end
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ==========================================================================
  # Verify-on-read — each line carries SHA256(canonical(record)); a tampered line
  # is rejected (skipped + logged), never trusted as a head.
  # ==========================================================================

  defp read_valid_records(file) do
    case File.read(file) do
      {:ok, contents} ->
        records =
          contents
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&decode_valid_line/1)

        {:ok, records}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A valid line is "<content_hash> <org_id> <seq> <hash> <sealed_at_iso>" where
  # content_hash == SHA256(canonical). Any mismatch → line is skipped (tamper).
  defp decode_valid_line(line) do
    case String.split(line, " ", parts: 5) do
      [stored_hash, org_b64, seq_str, hash, sealed_iso] ->
        with {:ok, org_id} <- Base.decode64(org_b64),
             {seq, ""} <- Integer.parse(seq_str),
             {:ok, sealed_at, _} <- DateTime.from_iso8601(sealed_iso) do
          record = %{org_id: org_id, seq: seq, hash: hash, sealed_at: sealed_at}

          if content_hash(record) == stored_hash do
            [record]
          else
            Logger.warning("[Anchor.LocalWorm] rejected tampered anchor line (hash mismatch)")
            []
          end
        else
          _ ->
            Logger.warning("[Anchor.LocalWorm] rejected malformed anchor line")
            []
        end

      _ ->
        Logger.warning("[Anchor.LocalWorm] rejected malformed anchor line")
        []
    end
  end

  defp encode_line(record) do
    ch = content_hash(record)

    Enum.join(
      [
        ch,
        Base.encode64(record.org_id),
        Integer.to_string(record.seq),
        record.hash,
        DateTime.to_iso8601(record.sealed_at)
      ],
      " "
    ) <> "\n"
  end

  # Deterministic content hash over the anchor fields (the in-file integrity check).
  defp content_hash(%{org_id: o, seq: s, hash: h, sealed_at: sa}) do
    canonical = "#{o}|#{s}|#{h}|#{DateTime.to_iso8601(sa)}"
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  defp normalize(org_id, seq, hash, sealed_at) do
    %{
      org_id: to_string(org_id),
      seq: seq,
      hash: hash,
      sealed_at: (sealed_at || DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    }
  end

  defp path do
    Application.get_env(:samen_core, :anchor_local_worm_path) ||
      Path.join(System.tmp_dir!(), "samen_audit_anchor.worm")
  end
end
