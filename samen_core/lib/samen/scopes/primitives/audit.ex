defmodule Samen.Scopes.Primitives.Audit do
  @moduledoc """
  Audit writers for the Primitives scope (T3.7).

  The Primitives scope table lists `audit` as an object. Per the scope-authoring
  guide (§6) and ADR-004 (§5): **a scope never defines its own audit table**. This
  module is the thin set of audit writers that call `Samen.AuditEvent.insert/2` —
  the existing T2.2 append-only, partitioned, REVOKE+trigger-guarded `aud_event` tier.

  ## Signature

  All writers take `(repo, entity, actor_id)` where `repo` is the Ecto repo that
  owns the `aud_event` table. This mirrors `Samen.Scopes.Support.Audit` and decouples
  the writers from config resolution (the caller owns the repo).

  ## Token-only discipline

  All rows carry ONLY opaque IDs, bounded enums, and numbers — never subject PII
  (no rendered_body, no signing_secret, no filename with personal data). The
  `no_plaintext_pii` oracle enforces this on the `aud_event` tier at every CI run.

  ## Audited events

  | event_type                          | subject_id       | detail                             |
  |-------------------------------------|------------------|------------------------------------|
  | `primitives.webhook.registered`     | webhook.id       | `"status=…"`                       |
  | `primitives.webhook.deleted`        | webhook.id       | `"org_id=…"`                       |
  | `primitives.feature_flag.toggled`   | flag.id          | `"enabled=… name=…"`              |
  | `primitives.notification.sent`      | notification.id  | `"channel=… status=…"`             |
  | `primitives.file.uploaded`          | file.id          | `"status=…"`                       |
  | `primitives.file.promoted`          | file.id          | `"scanner=… verdict=…"`            |
  """

  @doc """
  Emit a webhook registration audit event.

  `webhook` must have `:id`, `:org_id`, `:status` fields. No URL or signing_secret
  in the audit row (both are sensitive; secret is 🔒 vault-routed).
  """
  @spec webhook_registered(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def webhook_registered(repo, webhook, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(webhook.id),
      actor_id: actor_id,
      correlation_id: webhook.org_id,
      detail: "primitives.webhook.registered status=#{Map.get(webhook, :status, :active)}"
    })
  end

  @doc """
  Emit a webhook deletion audit event.
  """
  @spec webhook_deleted(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def webhook_deleted(repo, webhook, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(webhook.id),
      actor_id: actor_id,
      correlation_id: webhook.org_id,
      detail: "primitives.webhook.deleted"
    })
  end

  @doc """
  Emit a feature flag toggle audit event.

  `enabled` is a boolean — safe to log (bounded metric value).
  No flag name in the detail (names might be sensitive in operator context;
  the subject_id = flag.id is the authoritative reference).
  """
  @spec feature_flag_toggled(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def feature_flag_toggled(repo, flag, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(flag.id),
      actor_id: actor_id,
      correlation_id: flag.org_id,
      detail: "primitives.feature_flag.toggled enabled=#{Map.get(flag, :enabled, false)}"
    })
  end

  @doc """
  Emit a notification sent audit event.

  Only `channel` (bounded enum) and `status` (bounded enum) are in the detail.
  The `recipient_id` is an opaque UUID — included as it is NOT PII (bounded ID).
  The rendered_body is 🔒 vault-routed — never in the audit row.
  """
  @spec notification_sent(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def notification_sent(repo, notification, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(notification.id),
      actor_id: actor_id,
      correlation_id: notification.org_id,
      detail:
        "primitives.notification.sent channel=#{Map.get(notification, :channel, :in_app)} " <>
          "status=#{Map.get(notification, :status, :sent)}"
    })
  end

  @doc """
  Emit a file upload audit event.

  Only `status` (bounded enum) is in the detail. The filename and storage_key are
  NOT in the audit row (filename could be sensitive; storage_key is a credential).
  """
  @spec file_uploaded(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def file_uploaded(repo, file, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(file.id),
      actor_id: actor_id,
      correlation_id: file.org_id,
      detail: "primitives.file.uploaded status=#{Map.get(file, :status, :active)}"
    })
  end

  @doc """
  Emit a file promotion audit event (quarantine → active).

  Only the scanner module (bounded) and its `verdict` (bounded enum) are in the detail.
  The filename and storage_key are NOT in the audit row. Because auto-promotion via
  `Samen.Files.Scanner.Noop` is an explicit operator opt-in, this row is the honest,
  durable record that a file was cleared and by which scanner.
  """
  @spec file_promoted(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def file_promoted(repo, file, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(file.id),
      actor_id: actor_id,
      correlation_id: file.org_id,
      detail:
        "primitives.file.promoted scanner=#{inspect(Map.get(file, :scanner))} " <>
          "verdict=#{Map.get(file, :verdict, :clean)}"
    })
  end

  @doc """
  Emit a file blob-deletion audit event (the governed `Samen.Files.delete_file/3` /
  erasure-arm path — ADR-046 §4.3 D4/T130).

  Token-only + org-attributed: `subject_id = file.id`, `correlation_id = org_id`, and the
  detail carries ONLY the bounded booleans/counts `blob_deleted` (was the physical blob
  removed — i.e. was this the LAST reference) and `refs_remaining` (how many aliasing
  `File` rows still reference the blob). The `storage_key` (a credential-shaped reference)
  and the filename are NEVER in the audit row.
  """
  @spec file_blob_deleted(module(), map(), String.t() | nil, map()) ::
          {:ok, term()} | {:error, term()}
  def file_blob_deleted(repo, file, actor_id, meta) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(Map.get(file, :id)),
      actor_id: actor_id,
      correlation_id: Map.get(file, :org_id),
      detail:
        "primitives.file.blob_deleted blob_deleted=#{Map.get(meta, :blob_deleted)} " <>
          "refs_remaining=#{Map.get(meta, :refs_remaining)}"
    })
  end
end
