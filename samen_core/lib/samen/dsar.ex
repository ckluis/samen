defmodule Samen.Dsar do
  @moduledoc """
  DSAR — Data Subject Access Request export (F3.3; G19). The read-side mirror of
  `Samen.Erasure`: where erasure DESTROYS a subject's data, `export_subject/2`
  GATHERS it into a structured, plane-correct bundle a controller can hand a subject
  under GDPR Art. 15 / CCPA — and records the access on the tamper-evident audit log,
  exactly as erasure records the destruction.

  ## Walks the subject's vault (the authoritative PII store)

  A subject's PII lives as per-subject-encrypted rows in `pii_vault` (keyed by
  `subject_id`); domain rows carry only FK tokens. So the bundle is built by walking
  the subject's ACTIVE vault rows and resolving each to its plane-correct value, plus
  the subject's audit-chain trail (already token-only). This is the same subject-keyed
  spine `Samen.Erasure.shred/2` seals.

  ## Org-bound — NO cross-tenant leakage (the load-bearing red path), for ORGS not just planes

  `:org_id` is a HARD, caller-asserted precondition (ADR-046 §4.5), not an optional hint:
  the export rides the specific tenant org the caller's authorized scope (OrgScope) named.
  A missing org, or the reserved `"__global__"` system chain, is refused fail-closed
  (`{:error, :org_id_required}`) — an export never spans orgs and never rides the operator/
  system chain. The subject's audit-chain trail is filtered to THAT org (`ach_org_id`), so a
  subject with events on org A's chain AND org B's chain, exported scoped to org A, surfaces
  ONLY org-A events — org-B events are never in the bundle. This mirrors `Samen.Erasure.shred/2`'s
  org model exactly: the `pii_vault` is the GLOBAL, subject-keyed crypto-shred unit (ADR-001 §2 —
  it carries no `org_id`; `subject_id` IS the identity), so the vault walk is subject-keyed and
  the org authorization for it is the caller's REQUIRED asserted scope, while the per-org audit
  chain is where org-scoping bites structurally.

  ## Two-plane split — plaintext derives from a REAL authorization, never a caller boolean

  The bundle is built on a PLANE and never leaks across it. Plaintext is produced ONLY for:

    * `:tenant`   — the tenant exporting its OWN subject owns that PII → plaintext (no reveal
      grant needed; the tenant is the data owner).
    * `:operator` — cross-tenant / control plane → every value is `••••` (`Masked.mask/0`)
      UNLESS a GENUINE, live reveal grant (distinct-party approved) covers the subject. That
      decision is made by the REAL grant model (`Samen.Reveal.grant_checker/0` — default
      `DenyAll`), NEVER by a caller-asserted boolean: a caller cannot pass `grant?: true` to
      force plaintext. A masked value is NEVER the plaintext, NEVER the ciphertext, and NEVER a
      `vt_*`/token — the same discipline the per-plane masking tests enforce on every surface.

  The DEFAULT plane is `:operator` (fail-closed): an export with no explicit authorization masks
  — never plaintext-by-default. A shredded subject's field resolves to the `"[shredded]"`
  sentinel (the ciphertext is undecryptable — honest absence, not a fabricated value).

  ## Records the access — a HARD PRECONDITION of returning the bundle (O9)

  Every export appends a `dsar_export` event to the subject's hash chain (tokens
  only — plane + field count, never the exported plaintext), so a subject-access is
  itself on the tamper-evident lifecycle log. That access record is NON-REPUDIATION on a
  GDPR Art. 15 compliance surface — it is the load-bearing "who exported whose data"
  artifact. So the append is a PRECONDITION of handing back the bundle, NOT best-effort:
  if the audit append fails (repo down, missing `aud_chain` table, seq contention), the
  export FAILS with `{:error, {:audit_write_failed, reason}}` and the caller gets NO
  bundle. `export_subject/2` never returns an export it could not account for.
  """

  import Ecto.Query, only: [from: 2]

  alias Samen.AuditChain
  alias Samen.AuditChain.Entry
  alias Samen.Masked
  alias Samen.Reveal
  alias Samen.Reveal.Context
  alias Samen.Vault
  alias Samen.Vault.VaultRow

  @shredded_sentinel "[shredded]"

  @type plane :: :tenant | :operator

  @type bundle :: %{
          subject_id: String.t(),
          plane: plane(),
          exported_at: DateTime.t(),
          personal_data: [map()],
          audit_trail: [map()]
        }

  @doc """
  Export everything about `subject_id` as a plane-correct bundle.

  `opts`:
    * `:repo`     — the vault/chain repo (defaults to the erasure default repo).
    * `:plane`    — `:operator` (DEFAULT, fail-closed masked) or `:tenant` (the data owner,
      plaintext). Never plaintext-by-default: the default plane masks.
    * `:org_id`   — **REQUIRED** — the subject's org (the audit trail is filtered to it and the
      export event rides that org's chain). A missing org, or the reserved `"__global__"`
      chain, is refused with `{:error, :org_id_required}` (fail-closed; ADR-046 §4.5).
    * `:actor`    — operator-plane only: the operator principal whose LIVE reveal grant is
      checked against the REAL grant model. No actor / no grant → masked.
    * `:grant`    — override the grant checker module (defaults to `Samen.Reveal.grant_checker/0`;
      injectable for tests). There is NO caller-asserted `grant?` boolean — plaintext derives
      from a genuine grant, never a caller assertion.
    * `:actor_id` — who ran the export (recorded in the audit event).

  Returns `{:ok, bundle}` on success. The bundle NEVER contains a token or ciphertext;
  masked values are `Masked.mask/0`. Returns `{:error, :org_id_required}` if no real org was
  asserted, or `{:error, {:audit_write_failed, reason}}` if the mandatory `dsar_export` access
  record could not be written — the export is refused rather than handed back unaccounted-for (O9).
  """
  @spec export_subject(String.t(), keyword()) :: {:ok, bundle()} | {:error, term}
  def export_subject(subject_id, opts \\ []) when is_binary(subject_id) do
    repo = Keyword.get(opts, :repo) || default_repo()
    plane = Keyword.get(opts, :plane, :operator)
    actor = Keyword.get(opts, :actor)
    actor_id = Keyword.get(opts, :actor_id, "system:dsar")

    with {:ok, org_id} <- require_org(Keyword.get(opts, :org_id)) do
      masked? = masked?(plane, subject_id, actor, opts)

      personal_data = walk_vault(subject_id, repo, masked?)
      audit_trail = walk_audit(subject_id, org_id, repo)

      bundle = %{
        subject_id: subject_id,
        plane: plane,
        exported_at: DateTime.utc_now(),
        personal_data: personal_data,
        audit_trail: audit_trail
      }

      # The access record is a HARD PRECONDITION (O9): no non-repudiation record → no bundle.
      case record_export(repo, org_id, subject_id, actor_id, plane, length(personal_data)) do
        {:ok, _entry} -> {:ok, bundle}
        {:error, reason} -> {:error, {:audit_write_failed, reason}}
      end
    end
  end

  # Org binding is a HARD, caller-asserted precondition (ADR-046 §4.5): the export rides a
  # specific tenant org the caller's authorized scope named. A missing org, or the reserved
  # "__global__" system chain, is refused fail-closed — an export must never span orgs or ride
  # the operator/system chain. (The pii_vault carries no org_id — subject_id is the global
  # crypto-shred unit per ADR-001 — so this asserted org IS the vault-walk's authorization,
  # mirroring `Samen.Erasure.shred/2`.)
  defp require_org(nil), do: {:error, :org_id_required}

  defp require_org(org_id) do
    org_id = to_string(org_id)
    if org_id == AuditChain.global_org(), do: {:error, :org_id_required}, else: {:ok, org_id}
  end

  # The plane/grant decision. Plaintext is produced ONLY for the :tenant plane (the tenant owns
  # its own subject's PII, no reveal grant needed) or the :operator plane WITH a genuine, live
  # reveal grant covering the subject. Every other case — unknown plane, operator without a real
  # grant, no actor — masks (fail-closed). The default plane is :operator, so an export with no
  # explicit authorization masks: never plaintext-by-default.
  defp masked?(:tenant, _subject_id, _actor, _opts), do: false
  defp masked?(:operator, subject_id, actor, opts), do: not real_grant?(subject_id, actor, opts)
  defp masked?(_plane, _subject_id, _actor, _opts), do: true

  # Consult the REAL reveal grant model — NEVER a caller-asserted boolean. Requires a LITERAL
  # `true` from the (host-injected, therefore adversarial) grant checker: a truthy non-`true`
  # verdict must NOT admit plaintext (same strictness as `Samen.Api.PiiResolution` egress and
  # `Samen.AI.Chokepoint`). The DEFAULT checker is `Samen.Reveal.DenyAll` (fail-closed), and the
  # real `Samen.Reveal.Grants` requires an active, unexpired, distinct-party-approved grant for
  # (actor, subject_id) — so a caller passing `grant?: true` with no real grant gets `••••`.
  defp real_grant?(subject_id, actor, opts) do
    grant = Keyword.get(opts, :grant, Reveal.grant_checker())

    grant.granted?(%Context{
      actor: actor,
      subject_id: subject_id,
      resource: __MODULE__,
      action: :export_subject,
      label: :dsar
    }) === true
  end

  # Walk the subject's ACTIVE vault rows → plane-correct field entries. NEVER emits a
  # token or ciphertext; on the operator plane without a grant the value is `••••`.
  defp walk_vault(subject_id, repo, masked?) do
    repo.all(from(v in VaultRow, where: v.subject_id == ^subject_id, order_by: [asc: v.vault_name, asc: v.field_name]))
    |> Enum.map(fn %VaultRow{} = v ->
      %{
        vault: v.vault_name,
        field: v.field_name,
        label: v.label,
        state: v.state,
        value: resolve_value(v, subject_id, repo, masked?)
      }
    end)
  end

  # Masked plane → `••••` (never decrypt). Unmasked → reveal plaintext; a shredded /
  # unrevealable row is the honest `[shredded]` sentinel, never a fabricated value.
  defp resolve_value(_v, _subject_id, _repo, true), do: Masked.mask()

  defp resolve_value(%VaultRow{state: "shredded"}, _subject_id, _repo, false), do: @shredded_sentinel

  defp resolve_value(%VaultRow{token: token}, subject_id, repo, false) do
    case Vault.reveal(%Masked{token: token, label: :dsar}, repo, subject_id: subject_id) do
      {:ok, plaintext} -> plaintext
      {:error, _} -> @shredded_sentinel
    end
  end

  # The subject's audit-chain trail for THIS org — already token-only (event_type + timing +
  # bounded detail), safe to include verbatim. Org-bound: filtered on `ach_org_id` so an export
  # scoped to org A never surfaces the same subject's org-B chain entries (cross-org isolation).
  defp walk_audit(subject_id, org_id, repo) do
    repo.all(
      from(e in Entry,
        where: e.subject_id == ^subject_id and e.org_id == ^org_id,
        order_by: [asc: e.occurred_at]
      )
    )
    |> Enum.map(fn %Entry{} = e ->
      %{event_type: e.event_type, occurred_at: e.occurred_at, detail: e.detail}
    end)
  end

  # Append the DSAR access to the subject's chain (tokens only — never the payload).
  # Returns `AuditChain.append/2`'s `{:ok, entry} | {:error, reason}` VERBATIM — the caller
  # gates the bundle on it (O9). A raise (e.g. missing `aud_chain` table) is converted to an
  # `{:error, _}` so the failure is honest, NOT swallowed into a fake success.
  defp record_export(repo, org_id, subject_id, actor_id, plane, field_count) do
    AuditChain.append(
      %{
        org_id: org_id,
        event_type: "dsar_export",
        subject_id: subject_id,
        actor_id: actor_id,
        detail: "event=dsar_export plane=#{plane} fields=#{field_count}"
      },
      repo: repo
    )
  rescue
    e -> {:error, {:audit_append_raised, Exception.message(e)}}
  end

  @doc """
  Enumerate the distinct subject_ids touched on the audit chain (the breach-scope
  enumerator the breach-notification runbook consumes; F3.6). Tokens only — this
  reads subject_ids off the tamper-evident chain, never plaintext.

  `opts`:
    * `:repo`    — the chain repo.
    * `:org_id`  — restrict to one org (default: all orgs).
    * `:since`   — only events at/after this `DateTime` (default: no lower bound).
    * `:until`   — only events at/before this `DateTime` (default: no upper bound).

  Returns a sorted list of distinct subject_ids.
  """
  @spec affected_subjects(keyword()) :: [String.t()]
  def affected_subjects(opts \\ []) do
    repo = Keyword.get(opts, :repo) || default_repo()

    query = from(e in Entry, where: not is_nil(e.subject_id), distinct: true, select: e.subject_id)

    query
    |> maybe_filter(:org_id, Keyword.get(opts, :org_id))
    |> maybe_time(:since, Keyword.get(opts, :since))
    |> maybe_time(:until, Keyword.get(opts, :until))
    |> repo.all()
    |> Enum.sort()
  end

  defp maybe_filter(query, _key, nil), do: query
  defp maybe_filter(query, :org_id, org_id), do: from(e in query, where: e.org_id == ^to_string(org_id))

  defp maybe_time(query, _key, nil), do: query
  defp maybe_time(query, :since, dt), do: from(e in query, where: e.occurred_at >= ^dt)
  defp maybe_time(query, :until, dt), do: from(e in query, where: e.occurred_at <= ^dt)

  defp default_repo do
    Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :verify_repo) ||
      raise("Samen.Dsar needs a repo. Configure :samen_core, :non_pii_repo, MyApp.Repo")
  end
end
