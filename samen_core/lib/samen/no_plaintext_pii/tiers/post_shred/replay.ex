defmodule Samen.NoPlaintextPii.Tiers.PostShred.Replay do
  @moduledoc """
  **Post-shred check: stored session replays** (ADR-052 §2.4; the destruction oracle's
  `--subject <uuid> --tiers all` roster).

  A replay records a vault-routed value BY REFERENCE (`$ref` / `$record` → resource +
  primary key + attribute; ADR-052 §2.2 rule 1) and resolves it at view time. So erasure
  reaches replays for free — IF that holds for the rows actually stored. For the erased
  subject, this tier proves it on those rows:

    1. **Every stored frame that references the subject passes the frame schema** — no bare
       free string, nothing but references and bounded values (a frame the schema refuses
       could carry the subject's plaintext by value).
    2. **Every reference to the subject resolves to `[erased]`.** The frame is decoded
       (`Samen.Replay.Decoder`) and resolved by the player's own resolver
       (`Samen.Replay.Resolver`) on the frame org's TENANT plane — the plane that reads
       CLEAR, so a shred that did not take shows up as plaintext, not as a mask. Each
       reference to the subject must come back `:shredded` (`[erased]`); a row gone, an
       attribute no longer vault-routed or an empty value is accepted only while the KMS
       attests the subject `:shredded` (nothing is left to show). `:clear` or `:masked` (the
       key was NOT destroyed) is a violation.
    3. **No seeded plaintext probe** (`Samen.NoPlaintextPii.Context` `:plaintext_probes` — the
       game-day passes the subject's known values) appears in ANY replay row.

  Post-shred the subject's own plaintext cannot be recomputed (its key is gone), which is why
  (1) and (2) are structural and (3) takes the values from the caller. The CI-mode `:replay`
  tier decrypts and searches while the keys still exist.

  Speaks either way (a post-shred tier never returns `[]`): a `:pass` when the replay tables
  are not mounted, when no stored frame references the subject, or with the counts it
  proved; a `:violation` for each failure.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.NoPlaintextPii.Tiers.Replay, as: ReplayTier
  alias Samen.Replay.{Decoder, Record, Ref, Resolver}

  @tier :post_shred_replay

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred session replays: every stored frame referencing the subject passes the frame " <>
        "schema, every reference resolves to [erased], no seeded plaintext in any replay row"

  @impl true
  def check(%Context{subject_id: nil}),
    do: [
      Finding.violation(
        @tier,
        "<subject>",
        "the replay post-shred check requires --subject <uuid> — fail closed."
      )
    ]

  def check(%Context{repo: nil}),
    do: [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan the replay tables (fail closed)."
      )
    ]

  def check(%Context{repo: repo, subject_id: sid} = ctx) do
    case ReplayTier.mounted(repo) do
      :absent ->
        [
          Finding.pass(
            @tier,
            "replay",
            "the replay tables are not mounted on this host — no replay can reference #{sid}"
          )
        ]

      {:partial, present} ->
        [
          Finding.violation(
            @tier,
            "replay",
            "only #{inspect(present)} of the replay tables exist — fail closed."
          )
        ]

      {:error, e} ->
        [read_violation(e)]

      :mounted ->
        subject_findings(repo, String.downcase(sid)) ++ probe_findings(repo, ctx.plaintext_probes)
    end
  end

  # -- 1 + 2 -----------------------------------------------------------------------

  defp subject_findings(repo, sid) do
    where = {" AND rpf_payload::text LIKE '%' || $2 || '%'", [sid]}

    case ReplayTier.each_frame_page(repo, [], fn frame, acc -> [frame | acc] end, where) do
      {:error, e} ->
        [read_violation(e)]

      {:ok, []} ->
        [Finding.pass(@tier, "replay", "no stored replay frame references #{sid}")]

      {:ok, frames} ->
        frames = Enum.reverse(frames)
        {invalid, valid} = Enum.split_with(frames, &(ReplayTier.validate_stored(&1) != :ok))

        Enum.map(invalid, &schema_violation/1) ++ resolution_findings(valid, sid)
    end
  end

  defp resolution_findings(frames, sid) do
    outcomes =
      frames
      |> Enum.group_by(& &1.org_id)
      |> Enum.flat_map(fn {org, org_frames} ->
        refs = Enum.flat_map(org_frames, &subject_refs(&1, sid))
        if refs == [], do: [], else: resolve(refs, org)
      end)

    erased? = shredded?(sid)

    bad =
      Enum.reject(outcomes, fn outcome ->
        outcome == :shredded or (outcome in [:gone, :code_changed, :empty] and erased?)
      end)

    case {outcomes, bad} do
      {[], _} ->
        [
          Finding.pass(
            @tier,
            "replay",
            "#{length(frames)} stored frame(s) mention #{sid} only as a bare id (no reference to " <>
              "resolve); all pass the frame schema"
          )
        ]

      {_, []} ->
        [
          Finding.pass(
            @tier,
            "replay",
            "#{length(outcomes)} reference(s) to #{sid} in #{length(frames)} stored frame(s) " <>
              "resolve to [erased]; every frame passes the frame schema"
          )
        ]

      {_, bad} ->
        [
          Finding.violation(
            @tier,
            "replay",
            "#{length(bad)} of #{length(outcomes)} reference(s) to #{sid} in stored replay " <>
              "frames do NOT resolve to [erased] (#{inspect(Enum.frequencies(bad))}) — the " <>
              "subject's value is still readable through a replay: the shred did not take."
          )
        ]
    end
  end

  # The decoded `Ref`s to `sid` in one stored frame (inside records too).
  defp subject_refs(frame, sid) do
    %{payload: payload} = Decoder.frame(frame)

    payload
    |> Map.values()
    |> refs([])
    |> Enum.filter(&(&1.pk == sid))
  end

  defp refs(%Ref{} = ref, acc), do: [ref | acc]
  defp refs(%Record{fields: fields}, acc), do: refs(fields, acc)
  defp refs(%{__struct__: _}, acc), do: acc
  defp refs(%{} = map, acc), do: map |> Map.values() |> Enum.reduce(acc, &refs/2)
  defp refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &refs/2)

  defp refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &refs/2)

  defp refs(_other, acc), do: acc

  # Resolve on the frame org's TENANT plane (reads CLEAR — a shred that did not take shows).
  defp resolve(refs, org) do
    scope = %Samen.Scope{actor: %{org_id: org, plane: :tenant, role: :admin}}
    %{refs: reports} = Resolver.resolve(%{refs: refs}, scope)
    Enum.map(reports, & &1.outcome)
  rescue
    _ -> [:unresolvable]
  end

  defp shredded?(sid) do
    match?({:ok, %{state: :shredded}}, Samen.Kms.adapter().attest(sid))
  rescue
    _ -> false
  end

  defp schema_violation(frame) do
    Finding.violation(
      @tier,
      "replay_frame[#{frame.id}]",
      "a stored frame referencing the erased subject fails the replay frame schema — it could " <>
        "hold the subject's plaintext by value, which erasure never reaches."
    )
  end

  # -- 3 ---------------------------------------------------------------------------

  defp probe_findings(_repo, []), do: []

  defp probe_findings(repo, seeded) do
    probes = ReplayTier.probes_of(seeded)

    case ReplayTier.each_frame_page(repo, [], fn frame, acc ->
           if Enum.any?(string_leaves(frame.payload), &ReplayTier.hit?(&1, probes)),
             do: [frame.id | acc],
             else: acc
         end) do
      {:error, e} ->
        [read_violation(e)]

      {:ok, []} ->
        [
          Finding.pass(
            @tier,
            "replay",
            "no seeded plaintext probe of the subject appears in any replay row"
          )
        ]

      {:ok, hits} ->
        for id <- Enum.reverse(hits) do
          Finding.violation(
            @tier,
            "replay_frame[#{id}]",
            "the row contains a seeded plaintext value of the erased subject — erasure cannot " <>
              "reach a value stored in a replay row."
          )
        end
    end
  end

  defp string_leaves(v) when is_binary(v), do: [v]

  defp string_leaves(%{} = m),
    do: Enum.flat_map(m, fn {k, v} -> string_leaves(k) ++ string_leaves(v) end)

  defp string_leaves(l) when is_list(l), do: Enum.flat_map(l, &string_leaves/1)
  defp string_leaves(_), do: []

  defp read_violation(e) do
    Finding.violation(
      @tier,
      "replay",
      "could not read the replay tables (#{inspect(error_kind(e))}) — fail closed."
    )
  end

  defp error_kind(%{__struct__: mod}), do: mod
end
