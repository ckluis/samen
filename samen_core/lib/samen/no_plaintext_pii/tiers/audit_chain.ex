defmodule Samen.NoPlaintextPii.Tiers.AuditChain do
  @moduledoc """
  CI-mode tier: **the `aud_chain` hash-chain table carries only bounded-ID / token /
  enum / hash / timestamp / ciphertext columns — never a plaintext PII column**
  (T4.3; ADR-002 §2.4; doc *"the destruction oracle covers this tier too:
  mix samen.verify.no_plaintext_pii asserts the audit log holds tokens only"* :894).

  `aud_chain` is the tamper-evident audit chain (T4.3). Like the `aud_event` tier, it
  must hold only opaque ids, vault-FK tokens, bounded enum strings, hex hash digests,
  timestamps, operator-authored metadata, and the OPTIONAL per-subject
  **key-destroyable ciphertext** (a `bytea` column — not a plaintext type, so it cannot
  carry raw subject PII by shape; post-shred it is undecryptable bytes). A plaintext PII
  column on `aud_chain` would defeat the "immutable AND crypto-shreddable" resolution:
  the chain would then hold something the shred cannot reach.

  ## What the scan asserts (same engine as `Tiers.AudEvent`)

  1. **Name gate** — a plaintext-typed column whose name (after stripping the `ach_`
     prefix) matches the `Samen.PiiClassify` PII-identifier heuristic is a violation.
  2. **Allow-list gate (fail closed)** — every plaintext-typed column NOT on the known
     bounded-ID/token/enum/hash allow-list is a violation, unless registered `non_pii!`.
     A new unrecognised text column is a leak until removed/tokenised/registered.

  Non-plaintext physical types (`uuid`, `int8`, `timestamptz`, `bytea`) cannot carry raw
  subject PII by shape and are safe — critically, `ach_subject_ciphertext` is `bytea`
  (ciphertext, never plaintext).

  ## Absent table

  If `aud_chain` does not exist (a host that has not run the T4.3 migration), this tier
  returns NO finding — it only asserts over surfaces that EXIST (T1.8d).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiClassify

  @tier :aud_chain
  @table "aud_chain"

  # Allow-listed columns on aud_chain — bounded IDs / enums / hex hashes / timestamps.
  # (ciphertext is bytea, a non-plaintext type, so it need not be allow-listed here —
  # the type gate already clears it — but it is listed for documentation.)
  @allow_list ~w(
    ach_id
    ach_org_id
    ach_seq
    ach_prior_hash
    ach_hash
    ach_aud_id
    ach_event_type
    ach_subject_id
    ach_actor_id
    ach_correlation_id
    ach_detail
    ach_occurred_at
    ach_ciphertext_sha256
    ach_subject_ciphertext
    ach_inserted_at
  )

  @plaintext_udts ~w(varchar text bpchar date)

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "aud_chain hash-chain tier carries only bounded-ID/token/enum/hash/ciphertext columns (T4.3)"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot scan aud_chain (fail closed). " <>
          "Configure :verify_repo / :non_pii_repo / :reveal_grant_repo."
      )
    ]
  end

  def check(%Context{} = context) do
    case columns(context.repo, @table) do
      {:ok, []} ->
        []

      {:ok, cols} ->
        Enum.flat_map(cols, fn {name, udt} ->
          check_column(@table, name, udt, @allow_list, context)
        end)

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            @table,
            "could not introspect aud_chain columns (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  # ---------------------------------------------------------------------------

  defp check_column(table, name, udt, allow, context) do
    subject = "#{table}.#{name}"
    plaintext_type? = udt in @plaintext_udts

    cond do
      not plaintext_type? ->
        []

      Context.non_pii_exempt?(context, table, name) ->
        [
          Finding.exempt(
            @tier,
            subject,
            "registered non_pii! (plaintext-at-rest by design; erased by row-level redaction)"
          )
        ]

      PiiClassify.pii_name?(strip_prefix(name)) ->
        [
          Finding.violation(
            @tier,
            subject,
            "plaintext (#{udt}) column on aud_chain whose name matches a PII identifier " <>
              "pattern. The hash-chain audit tier must carry only opaque ids, tokens, hash " <>
              "digests, and key-destroyable ciphertext — never plaintext PII (a plaintext " <>
              "column would be something crypto-shred cannot reach). Remove it, tokenise " <>
              "it, encrypt it into ach_subject_ciphertext, or register a non_pii! override."
          )
        ]

      name not in allow ->
        [
          Finding.violation(
            @tier,
            subject,
            "unrecognised plaintext (#{udt}) column on aud_chain (not on the bounded-ID/" <>
              "token/enum/hash allow-list). A new text column on the audit chain is a leak " <>
              "until removed, tokenised, encrypted into ach_subject_ciphertext, or " <>
              "registered as a review-gated non_pii! override (fail closed)."
          )
        ]

      true ->
        []
    end
  end

  defp strip_prefix(name) do
    case String.split(name, "_", parts: 2) do
      [abbrev, rest] when byte_size(abbrev) == 3 -> rest
      _ -> name
    end
  end

  defp columns(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name, udt_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 " <>
          "ORDER BY column_name",
        [table]
      )

    {:ok, Enum.map(rows, fn [c, u] -> {c, u} end)}
  rescue
    e -> {:error, e}
  end
end
