defmodule Samen.Scopes.Identity.Audit do
  @moduledoc """
  Identity's `audit` surface (doc scope table `audit`) — a thin set of writers over
  the **existing** T2.2 `aud_event` tier. Identity does NOT define its own audit
  table (ADR-004 §5, scope-authoring guide §6): a scope contributes *writers* to the
  append-only, partitioned, REVOKE+trigger-guarded `aud_event` tier, never a new
  schema.

  Each writer inserts a token-only row (bounded IDs + operator tokens, never subject
  PII) via `Samen.AuditEvent.insert/2`, so the `no_plaintext_pii` `AudEvent` tier's
  invariant holds unchanged.

  ## Event types

  Identity uses the `"policy_denial"` and `"system"` bounded categories the
  `aud_event` schema already declares, plus operator-authored `aud_detail` tokens.
  """

  @doc """
  Record an Identity membership/role change. `actor_id` and `subject_id` are opaque
  user ids; `detail` is an operator-authored token string (e.g.
  `"role=member->admin"`) — never subject PII.
  """
  @spec role_changed(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def role_changed(repo, opts) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      actor_id: Keyword.get(opts, :actor_id),
      subject_id: Keyword.get(opts, :subject_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      detail: "identity.role_changed " <> to_string(Keyword.get(opts, :detail, ""))
    })
  end

  @doc "Record an api_key mint/revoke. Token-only (key id, membership id, plane)."
  @spec api_key_event(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def api_key_event(repo, opts) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      actor_id: Keyword.get(opts, :actor_id),
      subject_id: Keyword.get(opts, :subject_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      detail: "identity.api_key " <> to_string(Keyword.get(opts, :detail, ""))
    })
  end

  @doc "Record a denied Identity action (policy denial), for the audit trail."
  @spec policy_denied(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def policy_denied(repo, opts) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "policy_denial",
      actor_id: Keyword.get(opts, :actor_id),
      subject_id: Keyword.get(opts, :subject_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      detail: "identity.denied " <> to_string(Keyword.get(opts, :detail, ""))
    })
  end
end
