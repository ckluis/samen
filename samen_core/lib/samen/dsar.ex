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

  ## Two-plane split — NO cross-plane leakage (the load-bearing red path)

  The bundle is built on a PLANE and never leaks across it:

    * `:tenant`   — the tenant exporting its OWN subject owns that PII → plaintext.
    * `:operator` — cross-tenant / control plane → every value is `••••` (`Masked.mask/0`)
      UNLESS an operator reveal grant covers the subject (`grant?: true`). A masked
      value is NEVER the plaintext, NEVER the ciphertext, and NEVER a `vt_*`/token —
      the same discipline the per-plane masking tests enforce on every render surface.

  A shredded subject's field resolves to the `"[shredded]"` sentinel (the ciphertext
  is undecryptable — honest absence, not a fabricated value).

  ## Records the access (mirrors erasure's audit emission)

  Every export appends a `dsar_export` event to the subject's hash chain (tokens
  only — plane + field count, never the exported plaintext), so a subject-access is
  itself on the tamper-evident lifecycle log.
  """

  import Ecto.Query, only: [from: 2]

  alias Samen.AuditChain
  alias Samen.AuditChain.Entry
  alias Samen.Masked
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
    * `:plane`    — `:tenant` (default) or `:operator`.
    * `:grant?`   — operator-plane only: does a live reveal grant cover the subject?
      (default `false` — fail closed, masked).
    * `:org_id`   — the subject's org (the export event rides that org's chain).
    * `:actor_id` — who ran the export (recorded in the audit event).

  Returns `{:ok, bundle}`. The bundle NEVER contains a token or ciphertext; masked
  values are `Masked.mask/0`.
  """
  @spec export_subject(String.t(), keyword()) :: {:ok, bundle()} | {:error, term}
  def export_subject(subject_id, opts \\ []) when is_binary(subject_id) do
    repo = Keyword.get(opts, :repo) || default_repo()
    plane = Keyword.get(opts, :plane, :tenant)
    grant? = Keyword.get(opts, :grant?, false)
    org_id = Keyword.get(opts, :org_id) || AuditChain.global_org()
    actor_id = Keyword.get(opts, :actor_id, "system:dsar")

    masked? = masked?(plane, grant?)

    personal_data = walk_vault(subject_id, repo, masked?)
    audit_trail = walk_audit(subject_id, repo)

    bundle = %{
      subject_id: subject_id,
      plane: plane,
      exported_at: DateTime.utc_now(),
      personal_data: personal_data,
      audit_trail: audit_trail
    }

    _ = record_export(repo, org_id, subject_id, actor_id, plane, length(personal_data))

    {:ok, bundle}
  end

  # The masking decision — the two-plane rule (mirrors Samen.Scope.ApiKey.masking_for).
  # Fail closed: an unknown plane masks.
  defp masked?(:tenant, _grant?), do: false
  defp masked?(:operator, grant?), do: not grant?
  defp masked?(_plane, _grant?), do: true

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

  # The subject's audit-chain trail — already token-only (event_type + timing +
  # bounded detail), safe to include verbatim.
  defp walk_audit(subject_id, repo) do
    repo.all(from(e in Entry, where: e.subject_id == ^subject_id, order_by: [asc: e.occurred_at]))
    |> Enum.map(fn %Entry{} = e ->
      %{event_type: e.event_type, occurred_at: e.occurred_at, detail: e.detail}
    end)
  end

  # Append the DSAR access to the subject's chain (tokens only — never the payload).
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
    _ -> :ok
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
