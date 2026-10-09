defmodule Samen.NoPlaintextPii.Tiers.Replay do
  @moduledoc """
  CI-mode tier **`:replay`** (ADR-052 §2.4): the session-replay tables hold no plaintext.

  `replay_session` (`rps`) and `replay_frame` (`rpf`) are framework-owned and mounted in every
  host that serves tenant LiveViews (`Samen.Replay.Migration`). The capture path writes them
  through a sanitizer, the frame schema and `Samen.Replay.RowGuard` — this tier proves the
  ROWS, whatever wrote them (a raw SQL insert skips all three):

    1. **Every frame passes the frame schema** (`Samen.Replay.FrameSchema.validate/1`): no
       bare free string anywhere in its tree, every field of its declared bounded type, every
       identifier exactly what the sanitizer emits. A row the schema refuses is a violation
       (its content is never printed — only its id).
    2. **Every session row is what the kernel writes**: `view` a module name, `view_md5` a hex
       MD5, `actor_ref` the 64-hex HMAC pseudonym, `exit_reason` the bounded enum.
    3. **No referenced subject's plaintext is in any row.** Every subject a frame references
       (a `$ref` / `$record` primary key, a `$id`) has its vault rows decrypted HERE, through
       `Samen.Vault.reveal/3`, and each plaintext value (its string leaves, ≥ 4 characters) is
       searched for in every string of every replay row — keys included. Plus any
       caller-SEEDED probe (`Samen.NoPlaintextPii.Context` `:plaintext_probes`). A hit is a
       violation naming the row, never the value.

  ## Fail-closed

  No repo → violation. The two tables absent → no finding (the host does not mount replay;
  the tier asserts over surfaces that EXIST). Only ONE of the two present, a read that fails,
  more referenced subjects than the scan bound (#{5_000}), or a vault row that cannot be
  decrypted for a reason other than erasure (a KMS outage) → violation: what the tier could
  not prove is not passed.

  The scan is exhaustive (keyset pages of #{500} frames), not sampled: replay rows are bounded
  by retention (`Samen.Replay.retention_specs/1`, ≤ 90 days).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  import Ecto.Query, only: [from: 2]

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.Replay.FrameSchema

  @tier :replay
  @page 500
  @max_subjects 5_000
  @min_probe 4
  @hex32 ~r/\A[0-9a-f]{32}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @id_like ~r/\A[0-9a-f-]{32,}\z/
  @iso_date ~r/\A\d{4}-\d{2}-\d{2}\z/

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do:
      "replay_session / replay_frame rows carry no plaintext — every frame passes the frame " <>
        "schema, every session column is what the kernel writes, and no referenced subject's " <>
        "vault plaintext (or a seeded probe) appears in any row (ADR-052 §2.4)"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan the replay tables (fail closed)."
      )
    ]
  end

  def check(%Context{repo: repo} = ctx) do
    case mounted(repo) do
      :absent -> []
      :mounted -> scan(repo, ctx.plaintext_probes)
      {:partial, present} -> [partial_violation(present)]
      {:error, reason} -> [read_violation("information_schema", reason)]
    end
  end

  # ---------------------------------------------------------------------------

  defp scan(repo, seeded) do
    with {:ok, sessions} <- sessions(repo),
         {:ok, %{findings: frame_findings, subjects: subjects}} <- frame_pass(repo) do
      structural = Enum.flat_map(sessions, &session_findings/1) ++ frame_findings

      case vault_probes(repo, subjects) do
        {:ok, vault_probes} ->
          probes = Enum.uniq(vault_probes ++ probes_of(seeded))
          structural ++ content_findings(repo, sessions, probes)

        {:error, finding} ->
          structural ++ [finding]
      end
    else
      {:error, %Finding{} = finding} -> [finding]
      {:error, reason} -> [read_violation("replay tables", reason)]
    end
  end

  # -- 1/2: structure --------------------------------------------------------

  defp session_findings(%{id: id, view: view, md5: md5, actor: actor, exit: exit_reason}) do
    problems =
      [
        {not FrameSchema.module_name?(view), "view is not a module name"},
        {not (is_nil(md5) or Regex.match?(@hex32, md5)), "view_md5 is not a hex MD5"},
        {not (is_nil(actor) or Regex.match?(@hex64, actor)),
         "actor_ref is not the HMAC pseudonym"},
        {not (is_nil(exit_reason) or exit_reason in ~w(normal shutdown killed crash)),
         "exit_reason is outside the bounded enum"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    case problems do
      [] ->
        []

      _ ->
        [
          Finding.violation(
            @tier,
            "replay_session[#{id}]",
            Enum.join(problems, "; ") <>
              " — a replay session row holds only code identifiers and the actor pseudonym; " <>
              "this one was not written by the kernel (RowGuard)."
          )
        ]
    end
  end

  # Walk every frame once: schema findings + the subjects the frames reference.
  defp frame_pass(repo) do
    each_frame_page(repo, %{findings: [], subjects: MapSet.new()}, fn frame, acc ->
      acc =
        case validate_stored(frame) do
          :ok ->
            acc

          {:error, _path} ->
            %{acc | findings: [schema_violation(frame.id) | acc.findings]}
        end

      %{acc | subjects: collect_subjects(frame.payload, acc.subjects)}
    end)
    |> case do
      {:ok, acc} -> {:ok, %{acc | findings: Enum.reverse(acc.findings)}}
      other -> other
    end
  end

  defp schema_violation(id) do
    Finding.violation(
      @tier,
      "replay_frame[#{id}]",
      "the stored frame fails the replay frame schema (a bare free string, an undeclared field, " <>
        "or a value of the wrong bounded type) — it could carry plaintext. The capture path " <>
        "refuses such a frame; this row was written past it."
    )
  end

  @doc """
  `Samen.Replay.FrameSchema.validate/1` for a STORED row read in a fresh process (the oracle
  CLI). The schema accepts a key only when it names an EXISTING atom — exactly what the
  sanitizer writes — and under interactive code loading an assign key that only a not-yet-
  loaded module defines does not exist yet. So a frame that fails is re-checked once after
  every module of every loaded application has been loaded (what a release's embedded mode
  does at boot): a key that is no atom of ANY loaded code still fails.
  """
  @spec validate_stored(map()) :: :ok | {:error, String.t()}
  def validate_stored(frame) do
    case FrameSchema.validate(frame) do
      :ok ->
        :ok

      {:error, _} ->
        :ok = load_all_code()
        FrameSchema.validate(frame)
    end
  end

  @loaded_key {__MODULE__, :all_code_loaded}

  defp load_all_code do
    unless :persistent_term.get(@loaded_key, false) do
      for {app, _, _} <- Application.loaded_applications(),
          mod <- Application.spec(app, :modules) || [],
          do: Code.ensure_loaded(mod)

      :persistent_term.put(@loaded_key, true)
    end

    :ok
  end

  @doc false
  # The subject ids a decoded (JSON) payload references: `$ref` / `$record` primary keys and
  # `$id` values that are UUIDs.
  @spec collect_subjects(term(), MapSet.t()) :: MapSet.t()
  def collect_subjects(%{"$ref" => %{} = body}, acc), do: add_uuid(acc, body["pk"])

  def collect_subjects(%{"$record" => %{} = body}, acc),
    do: collect_subjects(body["fields"], add_uuid(acc, body["pk"]))

  def collect_subjects(%{"$id" => %{} = body}, acc), do: add_uuid(acc, body["value"])

  def collect_subjects(%{} = map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &collect_subjects/2)

  def collect_subjects(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_subjects/2)

  def collect_subjects(_other, acc), do: acc

  defp add_uuid(acc, v) do
    if Samen.Replay.Sanitizer.uuid?(v), do: MapSet.put(acc, String.downcase(v)), else: acc
  end

  # -- 3: content --------------------------------------------------------------

  # Decrypt every vault row of the referenced subjects; their plaintext is what must not be
  # in a replay row.
  defp vault_probes(repo, subjects) do
    case MapSet.size(subjects) do
      0 -> {:ok, []}
      n when n > @max_subjects -> {:error, too_many(n)}
      _ -> decrypt_probes(repo, MapSet.to_list(subjects))
    end
  end

  defp too_many(n) do
    Finding.violation(
      @tier,
      "replay_frame",
      "the replay rows reference #{n} subjects — above the scan bound (#{@max_subjects}). The " <>
        "content check cannot be proven over them (fail closed)."
    )
  end

  defp decrypt_probes(repo, ids) do
    tokens =
      repo.all(from(r in Samen.Vault.VaultRow, where: r.subject_id in ^ids, select: r.token))

    {plaintexts, unproven} =
      Enum.reduce(tokens, {[], 0}, fn token, {acc, n} ->
        case Samen.Vault.reveal(%Samen.Masked{token: token, label: nil}, repo) do
          {:ok, plaintext} -> {[plaintext | acc], n}
          {:error, :unavailable} -> {acc, n + 1}
          # Erased / never keyed / gone: no plaintext exists to leak.
          {:error, _} -> {acc, n}
        end
      end)

    if unproven == 0 do
      {:ok, probes_of(plaintexts)}
    else
      {:error,
       Finding.violation(
         @tier,
         "pii_vault",
         "#{unproven} vault row(s) of subjects referenced by replay frames could not be " <>
           "decrypted (KMS unavailable) — their plaintext cannot be searched for (fail closed)."
       )}
    end
  rescue
    e -> {:error, read_violation("pii_vault", e)}
  end

  @doc false
  # The searchable probes of plaintext values: each value's string leaves (a structured
  # value — a full name, an email list — is JSON), trimmed, of at least #{@min_probe} chars.
  @spec probes_of([String.t()]) :: [String.t()]
  def probes_of(values) do
    values
    |> Enum.flat_map(fn v ->
      case Jason.decode(v) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> value_leaves(decoded, [])
        _ -> [v]
      end
    end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.filter(&(String.length(&1) >= @min_probe))
    |> Enum.uniq()
  end

  defp content_findings(_repo, _sessions, []), do: []

  defp content_findings(repo, sessions, probes) do
    session_hits =
      for s <- sessions,
          leaf <- Enum.filter([s.view, s.md5, s.actor, s.exit], &is_binary/1),
          hit?(leaf, probes),
          uniq: true,
          do: "replay_session[#{s.id}]"

    frame_hits =
      case each_frame_page(repo, [], fn frame, acc ->
             if Enum.any?(leaves(frame.payload, []), &hit?(&1, probes)),
               do: ["replay_frame[#{frame.id}]" | acc],
               else: acc
           end) do
        {:ok, hits} -> Enum.reverse(hits)
        {:error, reason} -> {:error, reason}
      end

    case frame_hits do
      {:error, reason} ->
        [read_violation("replay_frame", reason)]

      hits ->
        Enum.map(session_hits ++ hits, fn subject ->
          Finding.violation(
            @tier,
            subject,
            "the row contains the plaintext of a subject a replay references (a decrypted vault " <>
              "value or a seeded probe). A replay stores references, never values (ADR-052 §2.2 " <>
              "rule 1) — this row holds a value."
          )
        end)
    end
  end

  @doc false
  # Is `leaf` (a string of a stored row) a hit for any probe? A date-shaped probe must equal
  # the leaf (a datetime leaf containing the same day is not that value); an id-shaped leaf
  # (UUID / hex) is never a hit (it cannot hold a name); otherwise case-insensitive substring.
  @spec hit?(String.t(), [String.t()]) :: boolean()
  def hit?(leaf, probes) do
    l = String.downcase(leaf)

    not Regex.match?(@id_like, l) and
      Enum.any?(probes, fn p ->
        if Regex.match?(@iso_date, p), do: l == p, else: String.contains?(l, p)
      end)
  end

  # The string VALUES of a decoded plaintext (its keys are field names, not the subject's data).
  defp value_leaves(v, acc) when is_binary(v), do: [v | acc]
  defp value_leaves(%{} = map, acc), do: map |> Map.values() |> Enum.reduce(acc, &value_leaves/2)
  defp value_leaves(list, acc) when is_list(list), do: Enum.reduce(list, acc, &value_leaves/2)
  defp value_leaves(_other, acc), do: acc

  # Every string in a decoded JSON term — keys and values.
  defp leaves(v, acc) when is_binary(v), do: [v | acc]

  defp leaves(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {k, v}, a -> leaves(v, leaves(k, a)) end)

  defp leaves(list, acc) when is_list(list), do: Enum.reduce(list, acc, &leaves/2)
  defp leaves(_other, acc), do: acc

  # -- DB ------------------------------------------------------------------------

  @doc false
  # `:mounted` (both tables), `:absent` (neither), `{:partial, present}` or `{:error, reason}`.
  @spec mounted(module()) :: :mounted | :absent | {:partial, [String.t()]} | {:error, term()}
  def mounted(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' " <>
          "AND table_name IN ('replay_session', 'replay_frame')",
        []
      )

    case rows |> List.flatten() |> Enum.sort() do
      ["replay_frame", "replay_session"] -> :mounted
      [] -> :absent
      present -> {:partial, present}
    end
  rescue
    e -> {:error, e}
  end

  defp sessions(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT rps_id::text, rps_view, rps_view_md5, rps_actor_ref, rps_exit_reason " <>
          "FROM replay_session ORDER BY rps_id",
        []
      )

    {:ok,
     Enum.map(rows, fn [id, view, md5, actor, exit_reason] ->
       %{id: id, view: view, md5: md5, actor: actor, exit: exit_reason}
     end)}
  rescue
    e -> {:error, e}
  end

  @doc false
  # Fold `fun` over EVERY stored frame (keyset pages), each as `%{id, org_id, seq, at_ms,
  # kind, payload}` with the payload decoded from its JSON TEXT (so a non-object payload or a
  # kind outside the closed set still loads and is judged by the schema). `where` narrows the
  # scan (`{sql, params}` appended with AND; params numbered from $2).
  @spec each_frame_page(module(), acc, (map(), acc -> acc), {String.t(), list()} | nil) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def each_frame_page(repo, acc, fun, where \\ nil) do
    do_pages(repo, "00000000-0000-0000-0000-000000000000", acc, fun, where)
  rescue
    e -> {:error, e}
  end

  defp do_pages(repo, after_id, acc, fun, where) do
    {extra_sql, extra_params} = where || {"", []}

    %{rows: rows} =
      repo.query!(
        "SELECT rpf_id::text, rpf_org_id::text, rpf_seq, rpf_at_ms, rpf_kind, rpf_payload::text " <>
          "FROM replay_frame WHERE rpf_id > $1::uuid#{extra_sql} ORDER BY rpf_id LIMIT #{@page}",
        [Ecto.UUID.dump!(after_id) | extra_params]
      )

    acc =
      Enum.reduce(rows, acc, fn [id, org, seq, at_ms, kind, payload], a ->
        decoded =
          case Jason.decode(payload || "") do
            {:ok, %{} = map} -> map
            _ -> :not_an_object
          end

        fun.(%{id: id, org_id: org, seq: seq, at_ms: at_ms, kind: kind, payload: decoded}, a)
      end)

    if length(rows) == @page,
      do: do_pages(repo, rows |> List.last() |> hd(), acc, fun, where),
      else: {:ok, acc}
  end

  defp partial_violation(present) do
    Finding.violation(
      @tier,
      "replay tables",
      "only #{inspect(present)} of replay_session/replay_frame exist — a half-mounted replay " <>
        "store cannot be proven (fail closed). Mount both with Samen.Replay.Migration."
    )
  end

  defp read_violation(what, reason) do
    Finding.violation(
      @tier,
      what,
      "could not read #{what} (#{inspect(error_kind(reason))}) — the replay tables cannot be " <>
        "proven plaintext-free (fail closed)."
    )
  end

  defp error_kind(%{__struct__: mod}), do: mod
  defp error_kind(other), do: other
end
