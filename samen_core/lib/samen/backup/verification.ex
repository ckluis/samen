defmodule Samen.Backup.Verification do
  @moduledoc """
  Backup VERIFICATION (L6 / T92) — the "did the backup actually work?" check.

  A backup that was *taken* is not a backup that *restores*. This module answers
  the real question: restore the artifact into a scratch database (through a
  `Samen.Backup.Restore` adapter) and prove the restored data matches an EXPECTED
  manifest — a per-table `{row_count, content checksum}`. Anything short of a
  full, matching round-trip is a FAILED verification, surfaced (never swallowed)
  and raised to the operator plane.

  ## The four honest outcomes

    * unconfigured target → `{:error, :not_configured}` (fail-honest; NEVER `{:ok}`)
    * restore step failed (corrupt/truncated/missing artifact) →
      `{:error, {:restore_failed, reason}}`
    * restored data does not match the expected manifest (missing table, wrong
      row count, checksum drift) → `{:error, {:verification_failed, diffs}}`
    * full matching round-trip → `{:ok, report}`

  The three error outcomes each emit `[:samen, :backup, :verification, :failed]`
  telemetry (the operator-plane alert, done-criteria #2). The success outcome emits
  `[:samen, :backup, :verification, :ok]`. All emitted metadata is TOKEN-BLIND
  (INV-2): table names, integer counts, and md5 CONTENT CHECKSUMS only — never a
  `vt_*` token, never a plaintext field value.

  ## Manifest

  A manifest is `%{table_name => %{count: non_neg_integer, checksum: hex_string}}`.
  `manifest/2` computes one from a live restored handle; `compare/2` is the pure
  gate. `expected` is supplied by the operator (captured from the live primary at
  backup time — see `docs/runbooks/backup-cadence.md`).
  """

  require Logger

  @telemetry_failed [:samen, :backup, :verification, :failed]
  @telemetry_ok [:samen, :backup, :verification, :ok]

  @ident ~r/^[a-z_][a-z0-9_]*$/

  @type manifest :: %{optional(String.t()) => %{count: non_neg_integer(), checksum: String.t()}}

  @doc """
  Verify a backup is restorable AND matches `expected_manifest`.

  Options:
    * `:adapter` — a `Samen.Backup.Restore` implementation (default
      `Samen.Backup.Restore.NotConfigured` — fail-honest).
    * `:config` — adapter config (creds / artifact location).
    * `:scratch` — scratch-DB descriptor passed to the adapter.
    * `:expected_manifest` — the manifest the restore MUST reproduce.
  """
  @spec verify(keyword()) ::
          {:ok, map()} | {:error, :not_configured | {:restore_failed, term()} | {:verification_failed, list()}}
  def verify(opts) do
    adapter = Keyword.get(opts, :adapter, Samen.Backup.Restore.NotConfigured)
    config = Keyword.get(opts, :config, %{})
    scratch = Keyword.get(opts, :scratch, %{})
    expected = Keyword.get(opts, :expected_manifest, %{})

    if adapter.configured?(config) do
      run(adapter, config, scratch, expected)
    else
      # Fail-honest: an unwired restore target proves NOTHING. It is emphatically
      # NOT a passing verification — surface it, never return {:ok}.
      emit_failure(:not_configured, %{reason: "not_configured"})
      {:error, :not_configured}
    end
  end

  defp run(adapter, config, scratch, expected) do
    case adapter.restore(config, scratch) do
      {:ok, handle} ->
        try do
          actual = manifest(handle, Map.keys(expected))

          case compare(expected, actual) do
            :ok ->
              report = %{tables: map_size(expected), verified_at: DateTime.utc_now()}
              emit_ok(report)
              {:ok, report}

            {:mismatch, diffs} ->
              # A restore that came back but does NOT match the primary — the exact
              # "silent bad backup" this job exists to catch.
              emit_failure(:verification_failed, %{diffs: token_blind_diffs(diffs)})
              {:error, {:verification_failed, diffs}}
          end
        after
          safe_cleanup(handle)
        end

      {:error, :not_configured} ->
        emit_failure(:not_configured, %{reason: "not_configured"})
        {:error, :not_configured}

      {:error, reason} ->
        # A real restore FAILURE (corrupt / truncated / missing artifact). Never
        # swallowed into a green result.
        emit_failure(:restore_failed, %{reason: inspect(reason)})
        {:error, {:restore_failed, reason}}
    end
  end

  @doc """
  Compute a token-blind manifest for `tables` from a live restored `handle`.
  Each entry is `%{count: n, checksum: md5_hex}` where the checksum is over the
  ORDER-INDEPENDENT set of row texts, so it detects content drift (a partial or
  corrupt restore) regardless of physical row order.
  """
  @spec manifest(Samen.Backup.Restore.handle(), [String.t()]) :: manifest()
  def manifest(handle, tables) do
    query = Map.fetch!(handle, :query)

    Map.new(tables, fn table ->
      unless Regex.match?(@ident, table) do
        raise ArgumentError, "unsafe table identifier in manifest: #{inspect(table)}"
      end

      sql = """
      SELECT count(*)::bigint,
             coalesce(md5(string_agg(md5(t::text), '' ORDER BY md5(t::text))), '') AS checksum
      FROM #{table} t
      """

      {:ok, %{rows: [[count, checksum]]}} = query.(sql, [])
      {table, %{count: count, checksum: checksum}}
    end)
  end

  @doc """
  Pure comparison gate. `:ok` iff EVERY expected table is present in `actual` with
  an identical row count AND checksum; otherwise `{:mismatch, diffs}`.

  This is the load-bearing guarantee: it must FAIL CLOSED. A missing table, a
  short row count, or a drifted checksum is a mismatch — a bad/partial/corrupt
  backup can never pass here.
  """
  @spec compare(manifest(), manifest()) :: :ok | {:mismatch, list()}
  def compare(expected, actual) do
    diffs =
      Enum.reduce(expected, [], fn {table, exp}, acc ->
        case Map.get(actual, table) do
          nil ->
            [{table, :missing_from_restore} | acc]

          ^exp ->
            acc

          got ->
            [{table, %{expected: exp, got: got}} | acc]
        end
      end)

    if diffs == [], do: :ok, else: {:mismatch, Enum.reverse(diffs)}
  end

  # ---- operator-plane alert (token-blind) ---------------------------------------

  defp emit_failure(kind, meta) do
    meta = Map.merge(%{kind: kind, ok: false}, meta)
    :telemetry.execute(@telemetry_failed, %{count: 1}, meta)
    Logger.error("backup verification FAILED (#{kind}) — operator action required: #{inspect(meta)}")
    :ok
  end

  defp emit_ok(report) do
    :telemetry.execute(@telemetry_ok, %{tables: report.tables}, %{ok: true})
    :ok
  end

  # Diffs carry table names + counts + checksums only — never plaintext/tokens.
  # This keeps the operator alert INV-2 token-blind even when the primary holds
  # vaulted PII: a checksum is a one-way hash of row text, not a reversible token.
  defp token_blind_diffs(diffs) do
    Enum.map(diffs, fn
      {table, :missing_from_restore} -> %{table: table, issue: "missing_from_restore"}
      {table, %{expected: exp, got: got}} -> %{table: table, expected: exp, got: got}
    end)
  end

  defp safe_cleanup(handle) do
    case Map.get(handle, :cleanup) do
      fun when is_function(fun, 0) ->
        try do
          fun.()
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end
  end
end
