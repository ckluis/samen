defmodule Samen.Scopes.Cms.Audit do
  @moduledoc """
  CMS scope audit writers — thin wrappers around the T2.2 `aud_event` tier.

  Per the scope-authoring guide §6: a scope **never defines its own audit table**.
  CMS audit-worthy lifecycle events (publish, archive) call
  `Samen.AuditEvent.insert/2` with **token-only** rows (bounded IDs + operator
  tokens, never subject PII). The `AudEvent` tier's `no_plaintext_pii` enforcement
  guarantees this automatically.

  ## Events emitted

    * `:cms_page_published`   — a page transitioned to :published
    * `:cms_page_archived`    — a page transitioned to :archived
    * `:cms_post_published`   — a post transitioned to :published
    * `:cms_post_archived`    — a post transitioned to :archived

  All events carry `org_id`, `actor_id`, and `subject_id` (the page/post UUID) as
  opaque IDs. `detail` carries a bounded enum (the event type + status transition) —
  never free text or authored content.

  Content *versioning* is NOT a governance event here: it is the E7 audit-on-write
  tier (`versioned: :snapshot` → `<Resource>.Version` rows, ADR-040 §6.5). The former
  `:cms_content_versioned` event was retired with the bespoke ContentVersion (T119) —
  the four audit tiers stay disjoint (§7.4), so a content version is not also mirrored
  into the governance `aud_event` hash-chain.
  """

  @doc """
  Emit a CMS audit event. `event_type` is a bounded atom (one of the events listed
  above). `attrs` must contain `org_id`, `actor_id`, and `subject_id` as opaque
  UUIDs. An optional `detail` map is included verbatim; callers MUST NOT put authored
  content or subject PII into `detail` — only bounded IDs and enums.
  """
  @spec emit(atom(), map()) :: {:ok, term()} | {:error, term()}
  def emit(event_type, attrs) when is_atom(event_type) and is_map(attrs) do
    valid_event_types = [
      :cms_page_published,
      :cms_page_archived,
      :cms_post_published,
      :cms_post_archived
    ]

    if event_type not in valid_event_types do
      {:error, {:unknown_cms_event, event_type}}
    else
      Samen.AuditEvent.insert(event_type, attrs)
    end
  end
end
