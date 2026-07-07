defmodule Samen.AuditChain.TenantView do
  @moduledoc """
  The tenant-plane read view over the audit chain (T4.3 clause (d); ADR-002 §4;
  doc *"a hash-chained, tenant-readable log the operator cannot edit"* :890).

  A tenant queries **their own org's** chain: `for_org/2` returns the org's chain
  entries (tenant-appropriate, non-PII projection) PLUS the verification status —
  both the in-DB `verify_chain` and the out-of-band `verify_against_anchor`
  (the wholesale-rewrite defense). The tenant can verify the log themselves; they
  do not trust the operator's word for it.

  ## Per-org scoping (no cross-org leakage — ADR-002 §2.1)

  `for_org/2` filters `ach_org_id == org_id`. Because the chain is per-org, the tenant
  sees ONLY their org's entries — no other org's sequence numbers, hashes, rate, or
  existence leak. The reserved `"__global__"` operator/system chain is NOT a tenant org
  and is not returned to any tenant.

  ## Projection (tenant-appropriate, token-only)

  Each returned entry is a plain map: `seq`, `event_type`, `subject_id` (the opaque
  token — a tenant may map it to their own record, it is never plaintext), `actor_id`
  (which operator acted), `correlation_id`, `detail` (operator metadata), `occurred_at`,
  `hash`. The raw `ach_subject_ciphertext` bytes and the `prior_hash` plumbing are NOT
  surfaced (the tenant does not need the ciphertext; they need the record that an event
  happened + proof it is untampered).

  ## Verification status

  `for_org/2` returns:

      %{
        org_id: org_id,
        entries: [ %{seq, event_type, subject_id, actor_id, correlation_id, detail,
                     occurred_at, hash}, … ],   # ordered by seq asc
        chain_verified: true | false,           # verify_chain result
        chain_error: nil | {reason, seq},       # first inconsistency, if any
        anchor_status: :verified | :no_anchor | {:error, reason},
        head_seq: integer | -1,
        head_hash: String.t()
      }

  `chain_verified: false` (or `anchor_status: {:error, :anchor_divergence}`) is the
  tenant-visible tamper signal — the doc's "detectable by the tenant."
  """

  alias Samen.AuditChain
  alias Samen.AuditChain.Entry

  import Ecto.Query, only: [from: 2]

  @global "__global__"

  @doc """
  The tenant's own org's chain entries + verification status. See moduledoc for the
  returned shape. `org_id` MUST be a real tenant org — the reserved `"__global__"`
  operator/system partition is refused (`{:error, :not_a_tenant_org}`).
  """
  @spec for_org(String.t(), keyword()) :: {:ok, map()} | {:error, term}
  def for_org(org_id, opts \\ []) do
    org_id = to_string(org_id)
    r = Keyword.get(opts, :repo, AuditChain.repo())

    if org_id == @global do
      {:error, :not_a_tenant_org}
    else
      entries =
        r.all(from(e in Entry, where: e.org_id == ^org_id, order_by: [asc: e.seq]))

      # verify_chain over the already-loaded entries (single load, no re-query).
      {chain_verified, chain_error, head} =
        case AuditChain.verify_entries(org_id, entries) do
          {:ok, summary} -> {true, nil, summary}
          {:error, err} -> {false, err, nil}
        end

      anchor_status =
        case AuditChain.verify_against_anchor(org_id, Keyword.put(opts, :repo, r)) do
          {:ok, status} -> status
          {:error, reason} -> {:error, reason}
        end

      {:ok,
       %{
         org_id: org_id,
         entries: Enum.map(entries, &project/1),
         chain_verified: chain_verified,
         chain_error: chain_error,
         anchor_status: anchor_status,
         head_seq: head && head.head_seq,
         head_hash: head && head.head_hash
       }}
    end
  end

  # Tenant-appropriate projection — token-only, no ciphertext bytes, no prior_hash plumbing.
  defp project(%Entry{} = e) do
    %{
      seq: e.seq,
      event_type: e.event_type,
      subject_id: e.subject_id,
      actor_id: e.actor_id,
      correlation_id: e.correlation_id,
      detail: e.detail,
      occurred_at: e.occurred_at,
      hash: e.hash
    }
  end
end
