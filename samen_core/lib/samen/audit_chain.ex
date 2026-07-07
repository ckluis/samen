defmodule Samen.AuditChain do
  @moduledoc """
  The hash-chained, tenant-readable, operator-uneditable audit chain + WORM anchor
  verification (T4.3; ADR-002; doc "Immutable and crypto-shreddable" :894).

  ## What this module is

  A per-org hash chain over the reveal / impersonation / erasure audit events. Each
  entry carries `prior_hash` + `hash = SHA256(prior_hash <> canonical_token_payload)`
  (ADR-002 §2.3). The payload is token-only; an OPTIONAL per-subject
  key-destroyable ciphertext column lets the chain be immutable AND crypto-shreddable
  (§2.4). `verify_chain/1` detects any edit, delete, or gap. `verify_against_anchor/2`
  detects a wholesale-rewrite even if the DB was replaced (the sealed head lives in an
  external WORM store the app role cannot rewrite).

  ## Append is same-transaction with the aud_event write

  `append/2` is the ONE write path. It:

    1. locks the org's chain tip (`SELECT … FOR UPDATE` on the max-seq row — a
       per-org advisory serialization so two concurrent appends can't both read the
       same tip and produce a seq collision / fork);
    2. computes `seq = prior.seq + 1` (or 0 for a new org chain), `prior_hash =
       prior.hash` (or genesis), and `hash` from the canonical payload;
    3. inserts the `aud_chain` row.

  It is designed to run INSIDE the caller's transaction (e.g. the T1.6 grant multi,
  the T4.1 impersonation open, the erasure multi) so the chain entry and the
  underlying event commit atomically — an event without a chain entry, or a chain
  entry without its event, never exists.

  ## Reuses, never duplicates

  - The T2.2 `aud_event` append-only enforcement (role REVOKE + trigger) — the
    `aud_chain` migration reuses the identical pattern.
  - The T1.6 / T4.1 audit writers — `Samen.AuditChain.Writer` wraps
    `Samen.AuditEvent.insert/2` so the existing callers gain a chain entry with no
    per-caller rewrite.
  - The ADR-001 per-subject DEK — the subject ciphertext is encrypted under the
    SAME key the vault uses, so one shred makes it undecryptable.
  """

  alias Samen.AuditChain.{Entry, Canonical}
  alias Samen.Kms

  import Ecto.Query, only: [from: 2]

  @global_org "__global__"

  @doc "The reserved chain partition for org-less operator/system events."
  @spec global_org() :: String.t()
  def global_org, do: @global_org

  @doc "The Ecto repo backing the chain. Configured via :audit_chain_repo (falls back to :reveal_grant_repo)."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :audit_chain_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      raise "Samen.AuditChain needs a repo: config :samen_core, :audit_chain_repo, MyApp.Repo"
  end

  # ==========================================================================
  # Append (the one write path)
  # ==========================================================================

  @doc """
  Append an entry to the org's chain. Runs inside the caller's transaction (pass
  `:repo` bound to the transaction connection, or call from within `repo.transaction`).

  `attrs` (all token-only):
    * `:org_id`         — the org chain (defaults to `"__global__"` for org-less events)
    * `:event_type`     — bounded enum ("reveal" | "impersonation" | "erasure" | …)
    * `:subject_id`     — subject UUID / token (NOT plaintext)
    * `:actor_id`       — operator actor id
    * `:aud_id`         — the aud_event row this seals (opaque UUID)
    * `:correlation_id` — request / grant / session id
    * `:detail`         — operator metadata (allow-listed T2.2 field)
    * `:occurred_at`    — event time (defaults to now)
    * `:subject_payload` — OPTIONAL subject-linked plaintext to store as per-subject
      key-destroyable ciphertext (encrypted under the subject's DEK; NULL if absent)

  Returns `{:ok, %Entry{}}` or `{:error, term}`.
  """
  @spec append(map(), keyword()) :: {:ok, Entry.t()} | {:error, term}
  def append(attrs, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    org_id = to_string(Map.get(attrs, :org_id) || Map.get(attrs, "org_id") || @global_org)

    with {:ok, ciphertext} <- encrypt_subject_payload(attrs) do
      do_append(r, org_id, attrs, ciphertext)
    end
  end

  defp do_append(r, org_id, attrs, ciphertext) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Lock the tip for this org so concurrent appends serialize (no seq fork).
    prior = tip_locked(r, org_id)
    {seq, prior_hash} =
      case prior do
        nil -> {0, Canonical.genesis()}
        %Entry{} = p -> {p.seq + 1, p.hash}
      end

    ct_digest = Canonical.ciphertext_sha256(ciphertext)
    occurred_at = fetch_dt(attrs, :occurred_at) || now

    payload = %{
      org_id: org_id,
      seq: seq,
      aud_id: get(attrs, :aud_id),
      event_type: to_string(get(attrs, :event_type) || "system"),
      subject_id: get(attrs, :subject_id),
      actor_id: get(attrs, :actor_id),
      correlation_id: get(attrs, :correlation_id) && to_string(get(attrs, :correlation_id)),
      detail: get(attrs, :detail),
      occurred_at: DateTime.to_iso8601(occurred_at),
      ciphertext_sha256: ct_digest
    }

    hash = Canonical.hash(prior_hash, payload)

    row =
      %Entry{}
      |> Ecto.Changeset.cast(
        %{
          org_id: org_id,
          seq: seq,
          prior_hash: prior_hash,
          hash: hash,
          aud_id: get(attrs, :aud_id),
          event_type: payload.event_type,
          subject_id: payload.subject_id,
          actor_id: payload.actor_id,
          correlation_id: payload.correlation_id,
          detail: payload.detail,
          occurred_at: occurred_at,
          ciphertext_sha256: ct_digest,
          subject_ciphertext: ciphertext,
          inserted_at: now
        },
        [
          :org_id, :seq, :prior_hash, :hash, :aud_id, :event_type, :subject_id,
          :actor_id, :correlation_id, :detail, :occurred_at, :ciphertext_sha256,
          :subject_ciphertext, :inserted_at
        ]
      )
      |> Ecto.Changeset.validate_required([:org_id, :seq, :prior_hash, :hash, :event_type])

    r.insert(row)
  end

  # The current tip (max seq) for the org, row-locked. nil for a fresh chain.
  defp tip_locked(r, org_id) do
    r.one(
      from(e in Entry,
        where: e.org_id == ^org_id,
        order_by: [desc: e.seq],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  defp encrypt_subject_payload(attrs) do
    case get(attrs, :subject_payload) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      payload when is_binary(payload) ->
        subject_id = get(attrs, :subject_id)

        if is_binary(subject_id) do
          case Kms.adapter().unwrap(subject_id) do
            {:ok, dek} -> {:ok, Kms.Crypto.encrypt(dek, payload)}
            {:error, reason} -> {:error, {:subject_key_unavailable, reason}}
          end
        else
          {:error, :subject_payload_requires_subject_id}
        end
    end
  end

  # ==========================================================================
  # verify_chain/1 — detect edit, delete, gap
  # ==========================================================================

  @doc """
  Verify the org's entire chain. Recomputes every entry's hash from its stored
  fields and asserts:

    * seq is dense and gap-free from 0 (a DELETE breaks this);
    * seq-0's prior_hash is the genesis constant;
    * each entry's prior_hash equals the previous entry's stored hash (link);
    * each entry's stored hash equals the recomputed hash (an EDIT breaks this).

  Returns `{:ok, %{org_id, entries, head_seq, head_hash}}` on success, or
  `{:error, {reason, seq}}` on the first inconsistency.

  An EMPTY chain (no entries for the org) verifies `{:ok, ... entries: 0}` — there
  is nothing to tamper with. Callers that require a non-empty chain check `entries`.
  """
  @spec verify_chain(String.t(), keyword()) ::
          {:ok, map()} | {:error, {atom(), non_neg_integer()}}
  def verify_chain(org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())

    entries =
      r.all(
        from(e in Entry, where: e.org_id == ^to_string(org_id), order_by: [asc: e.seq])
      )

    verify_entries(to_string(org_id), entries)
  end

  @doc """
  Verify an already-loaded list of entries (ordered by seq). Used by the tenant
  view (which loads the entries once) and the anchor check. Same semantics as
  `verify_chain/2`.
  """
  @spec verify_entries(String.t(), [Entry.t()]) ::
          {:ok, map()} | {:error, {atom(), non_neg_integer()}}
  def verify_entries(org_id, entries) do
    do_verify(entries, 0, Canonical.genesis(), org_id)
  end

  defp do_verify([], expected_seq, prior_hash, org_id) do
    head_seq = if expected_seq == 0, do: -1, else: expected_seq - 1

    {:ok,
     %{
       org_id: org_id,
       entries: expected_seq,
       head_seq: head_seq,
       head_hash: if(expected_seq == 0, do: Canonical.genesis(), else: prior_hash)
     }}
  end

  defp do_verify([%Entry{} = e | rest], expected_seq, prior_hash, org_id) do
    cond do
      e.seq != expected_seq ->
        {:error, {:seq_gap, expected_seq}}

      e.prior_hash != prior_hash ->
        {:error, {:broken_link, e.seq}}

      true ->
        recomputed = Canonical.hash(e.prior_hash, payload_of(e))

        if recomputed != e.hash do
          {:error, {:hash_mismatch, e.seq}}
        else
          do_verify(rest, expected_seq + 1, e.hash, org_id)
        end
    end
  end

  # The canonical payload of a stored entry (mirrors do_append's payload map).
  defp payload_of(%Entry{} = e) do
    %{
      org_id: e.org_id,
      seq: e.seq,
      aud_id: e.aud_id,
      event_type: e.event_type,
      subject_id: e.subject_id,
      actor_id: e.actor_id,
      correlation_id: e.correlation_id,
      detail: e.detail,
      occurred_at: DateTime.to_iso8601(e.occurred_at),
      ciphertext_sha256: e.ciphertext_sha256
    }
  end

  # ==========================================================================
  # Anchor: seal + verify_against_anchor
  # ==========================================================================

  @doc "The current head anchor `{org_id, seq, hash}` for the org (from the live DB), or :none."
  @spec current_head(String.t(), keyword()) :: {:ok, map() | :none}
  def current_head(org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())

    case r.one(
           from(e in Entry,
             where: e.org_id == ^to_string(org_id),
             order_by: [desc: e.seq],
             limit: 1
           )
         ) do
      nil ->
        {:ok, :none}

      %Entry{} = e ->
        {:ok, %{org_id: e.org_id, seq: e.seq, hash: e.hash, sealed_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Seal the org's current chain head into the WORM anchor store. Returns
  `{:ok, anchor}` on a fresh seal, `{:ok, :nothing_to_seal}` for an empty chain, or
  `{:error, term}`.
  """
  @spec seal(String.t(), keyword()) :: {:ok, map() | :nothing_to_seal} | {:error, term}
  def seal(org_id, opts \\ []) do
    anchor_mod = Keyword.get(opts, :anchor, Samen.Anchor.adapter())

    case current_head(org_id, opts) do
      {:ok, :none} ->
        {:ok, :nothing_to_seal}

      {:ok, head} ->
        case anchor_mod.seal(head) do
          {:ok, _receipt} -> {:ok, head}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Verify the live DB chain agrees with the sealed WORM head (ADR-002 §3.3 — the
  wholesale-rewrite defense).

  Asserts: the live chain contains an entry at the sealed `seq` whose `hash`
  equals the sealed `hash`, AND the live head seq is `>=` the sealed seq (the chain
  only grows). A rewritten-history attack produces a live entry at the sealed seq
  with a DIFFERENT hash → `{:error, :anchor_divergence}`, even though the rebuilt
  chain internally verify_chains clean.

  Returns:
    * `{:ok, :verified}` — live chain matches the sealed head
    * `{:ok, :no_anchor}` — nothing sealed yet for this org (no divergence to detect)
    * `{:error, :anchor_divergence}` — live chain contradicts the sealed head
    * `{:error, :truncated_below_anchor}` — live head is BELOW the sealed seq (rows
      lost / rolled back past a seal)
    * `{:error, term}` — anchor store unreachable (fail closed)
  """
  @spec verify_against_anchor(String.t(), keyword()) ::
          {:ok, :verified | :no_anchor} | {:error, term}
  def verify_against_anchor(org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    anchor_mod = Keyword.get(opts, :anchor, Samen.Anchor.adapter())
    org_id = to_string(org_id)

    case anchor_mod.read_head(org_id) do
      {:ok, :none} ->
        {:ok, :no_anchor}

      {:ok, %{seq: sealed_seq, hash: sealed_hash}} ->
        live_at_seq =
          r.one(
            from(e in Entry,
              where: e.org_id == ^org_id and e.seq == ^sealed_seq,
              select: e.hash,
              limit: 1
            )
          )

        head_seq =
          r.one(from(e in Entry, where: e.org_id == ^org_id, select: max(e.seq)))

        cond do
          is_nil(live_at_seq) or is_nil(head_seq) or head_seq < sealed_seq ->
            {:error, :truncated_below_anchor}

          live_at_seq != sealed_hash ->
            {:error, :anchor_divergence}

          true ->
            {:ok, :verified}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ==========================================================================
  # Internal helpers
  # ==========================================================================

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp fetch_dt(attrs, key) do
    case get(attrs, key) do
      %DateTime{} = dt -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end
end
