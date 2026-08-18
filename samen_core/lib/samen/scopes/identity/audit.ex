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

  @doc """
  Record an auth-lifecycle event (ADR-035 §5 A10 taxonomy; extends the
  `api_key_event` precedent — the FULL notification+audit fan-out for every
  `auth.*` event kind is T09's contract; this is the audit HALF, used
  directly by A2/A3's confirm/reset consume paths). `opts`:

    * `:event` — REQUIRED. The bounded `auth.*` event (atom or string, e.g.
      `"auth.password_reset"` / `:email_verified`) — token-only, never PII.
    * `:actor_id` / `:subject_id` — opaque credential/user ids.
    * `:correlation_id` — optional correlation ref.
    * `:detail` — optional operator-authored token string, never subject PII.
  """
  @spec auth_event(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def auth_event(repo, opts) do
    event = Keyword.fetch!(opts, :event)
    extra = Keyword.get(opts, :detail)

    detail =
      case extra do
        nil -> "identity.#{event}"
        _ -> "identity.#{event} #{extra}"
      end

    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      actor_id: Keyword.get(opts, :actor_id),
      subject_id: Keyword.get(opts, :subject_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      detail: detail
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
