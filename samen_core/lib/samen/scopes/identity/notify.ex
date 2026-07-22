defmodule Samen.Scopes.Identity.Notify do
  @moduledoc """
  Identity's `notify` half of the ADR-035 §5 A10 auth-event fan-out (T09's
  contract). Every `auth.*` event kind in the A10 taxonomy table lands BOTH in
  the `aud_event` tier (`Samen.Scopes.Identity.Audit.auth_event/2`) AND,
  where the taxonomy marks it `✓`, dispatches an in-app notification through
  the KERNEL `Samen.Notifications.Engine` (record + suppression-aware
  dispatch + id-only PubSub envelope — the engine's existing contract,
  unchanged). This module is the identity-specific CALLER seam over that
  engine: it resolves an `auth.*` event's recipient (an opaque credential id)
  to the `{org_id, user_id}` pair the engine's `notify/emit` request shape
  requires, and builds a TOKEN-BLIND body.

  ## Token-blind by construction (ADR-035 §5 A10)

  `rendered_body` here is ALWAYS a fixed, operator-authored copy string —
  never string-interpolated with an email address, a raw token, or any other
  vaulted field. The Notification record's `rendered_body` column is itself
  vault-routed (`Samen.Notifications.Engine`'s own PII discipline), so even a
  token-blind body is stored encrypted at rest — but the bar this module
  holds is stricter: the body never CONTAINS PII in the first place, so no
  masking proof is even reachable through this seam (INV-1's belt AND
  braces — vault-routed storage, and nothing sensitive ever enters the
  string).

  ## Recipient resolution — no new lookup primitive

  `Identity.User` already carries its own `org_id` (set at creation —
  `Samen.Identity.Register.create_user/3`, `Samen.Identity.Invite`'s join,
  `Samen.Identity.OidcLink`'s provision path). Resolving a credential's
  notification recipient is therefore a single `User` read filtered on
  `credential_id` — no new join table, no `Samen.Auth.OrgActor` dependency
  (that module resolves ROLE-bearing per-org ACTORS for authorization
  decisions; this module only needs an org+user pair to address a
  notification). A credential linked to more than one org's `User` (the
  A5/T05 invite-join case) notifies the FIRST resolved org only — documented
  as this module's one simplification, not a correctness gap (the credential
  owner sees the notice in at least one org's inbox either way).

  ## Best-effort, never a regression on the primary write (the SlaBreachWorker/
  chat "chat_mention" precedent)

  Every function here calls through `Samen.Notifications.Engine.emit/2` (the
  BEST-EFFORT half of the engine's public API — never raises, logs and
  returns `{:error, reason}` on an unwired/failed engine) and additionally
  never raises itself: an unresolvable recipient (`:error` from
  `resolve_recipient/2`) is a quiet no-op, not a crash. The auth-lifecycle
  write this rides alongside (email verify, password reset, 2FA
  enroll/disable, recovery-code consume) is ALWAYS the load-bearing act;
  losing a notification is never allowed to unwind it.
  """

  require Ash.Query

  alias Samen.Notifications.Engine

  @type user_mods :: module()

  @doc """
  Resolve `credential_id` to the `{org_id, user_id}` pair a notification
  addresses. `{:ok, %{org_id:, user_id:}}` on the first `User` row the
  credential owns, `:error` when the credential has no linked `User` (a
  malformed/mid-transaction state that should never reach here in practice,
  but is refused quietly rather than raising).
  """
  @spec resolve_recipient(user_mods(), String.t()) ::
          {:ok, %{org_id: String.t(), user_id: String.t()}} | :error
  def resolve_recipient(user_mod, credential_id) when is_binary(credential_id) do
    user_mod
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.Query.ensure_selected([:id, :org_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{id: user_id, org_id: org_id}] -> {:ok, %{org_id: org_id, user_id: user_id}}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def resolve_recipient(_user_mod, _credential_id), do: :error

  @doc """
  Dispatch a token-blind `auth.*` in-app notification directly to `org_id` /
  `recipient_id` (already-resolved caller — e.g. an org-admin fan-out where
  the recipient is NOT the credential owner, like `auth.invite_accepted`'s
  inviter/admin notice). `event` is the bounded ADR-035 §5 A10 event kind
  WITHOUT the `auth.` prefix (e.g. `"totp_enrolled"`) — this function adds
  it, so every Notification row's `event_type` matches the taxonomy table
  literally (`"auth.totp_enrolled"`).
  """
  @spec security_notice(String.t(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, struct()} | {:ok, :suppressed} | {:error, term()}
  def security_notice(org_id, recipient_id, event, body, metadata \\ %{}, opts \\ [])
      when is_binary(org_id) and is_binary(recipient_id) and is_binary(event) and is_binary(body) do
    Engine.emit(
      %{
        org_id: org_id,
        recipient_id: recipient_id,
        event_type: "auth.#{event}",
        channel: :in_app,
        rendered_body: body,
        metadata: metadata
      },
      opts
    )
  end

  @doc """
  Resolve `credential_id`'s recipient (`resolve_recipient/2`) and dispatch a
  token-blind `auth.*` notification to the credential OWNER — the common
  case (email verified, password reset, 2FA enrolled/disabled, a recovery
  code consumed: the notified party IS the account the event happened to).
  A silent no-op when the credential resolves to no `User` row.
  """
  @spec notify_credential(user_mods(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, struct()} | {:ok, :suppressed} | {:error, term()} | :ok
  def notify_credential(user_mod, credential_id, event, body, metadata \\ %{}, opts \\ []) do
    case resolve_recipient(user_mod, credential_id) do
      {:ok, %{org_id: org_id, user_id: user_id}} ->
        security_notice(org_id, user_id, event, body, metadata, opts)

      :error ->
        :ok
    end
  end
end
