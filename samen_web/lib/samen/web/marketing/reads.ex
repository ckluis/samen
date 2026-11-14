defmodule Samen.Web.Marketing.Reads do
  @moduledoc """
  The framework Marketing / outreach read + write layer (ADR-011 §7). Reads the host's
  materialized Marketing scope resources through `Samen.Web.Mount.resource/2` — the same
  host-parameterization seam CRM uses, so the same code reads Driftwood's Marketing inside
  Driftwood and PawChart's inside PawChart with no host module named here.

  All reads go through Ash so `OrgScope` + vault masking apply.

  ## The 🔒 PII surface — Subscriber.email

  `Subscriber.email` is vault-routed PII resolved through `Samen.Api.PiiResolution.resolve/4`,
  exactly like CRM `Person.emails`:

    * TENANT plane — the org reads its OWN subscribers' email in CLEAR (it owns them + may
      email them);
    * OPERATOR / impersonation plane — the SAME field renders `%Masked{}` (→ ••••). An
      operator viewing a tenant's campaign sees `••••` for every recipient, and the send row
      itself carries NO email (only the opaque `subscriber_id`), so nothing leaks on the
      operator plane by construction.

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a vault token out of
  a `%Masked{}`, and NEVER introduces a "show plaintext" code path. Plaintext reaches the
  LiveView only if the shared `PiiResolution` resolver already resolved it. A resolver failure
  keeps `%Masked{}` (no plaintext downgrade).

  ## Consent / suppression enforcement (the load-bearing red path)

  `enqueue_send/3` is the ONLY send path the outreach UI uses. Suppression is enforced by the
  KERNEL `Send.:create_checked` action — an `OrgScope`-inheriting Ash read of THIS mount's own
  `Suppression` resource (portable across any mount abbrev, ADR-014 §4). We no longer duplicate
  the check here (the old framework `refuse_if_suppressed/3` existed only because the kernel
  hardcoded the demo-abbrev `msp_suppression` table; that hardcode is gone). `create_send/3`
  maps the kernel's suppression refusal back to `{:error, :suppressed}` so the UI still renders
  "suppressed — skipped" per recipient. The consent/status gate (`refuse_if_undeliverable/3`)
  stays — it is a distinct concern (an `:unsubscribed`/`:bounced` subscriber is undeliverable
  even with no suppression row). A refused send writes no send row and enqueues no Oban job;
  a delivered send (1) creates the send via `:create_checked` (which also layers the kernel's
  same-org-FK guard), and (2) enqueues the `Samen.Scopes.Marketing.SendWorker` Oban job with
  TOKEN-ONLY args (`send_id` / `org_id` / `subscriber_id` — never the email).
  """

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Reads.Guard

  # A3 read-bounding (WS-A design §1.1 "read! elimination"): every non-page read on the
  # Marketing surfaces carries an explicit limit. Detail sub-lists (a campaign's sends,
  # a compose page's templates/segments) are capped here; the LIST surfaces read through
  # the keyset-paginated `*_page/3` fns below (bounded by construction via
  # `Samen.Web.Reads.page!/3`).
  @detail_limit 200

  # ---------------------------------------------------------------------------
  # Reads — campaigns / templates / segments / subscribers / events
  # ---------------------------------------------------------------------------

  @doc """
  Read Marketing campaigns for `scope`, newest-first, capped at `#{@detail_limit}` rows
  (A3 read-bounding); the Campaigns page itself reads through the paginated
  `campaigns_page/3` — this remains only as a lookup read. Non-PII.
  """
  def campaigns(mount, scope), do: campaigns_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `campaigns/2` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`; an outage is not an empty list."
  def campaigns_result(mount, scope) do
    Guard.run(:marketing_campaigns, scope, fn ->
      Mount.resource(mount, Campaign)
      |> Ash.Query.ensure_selected([:name, :description, :status, :scheduled_at, :sent_at, :custom])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read ONE keyset page of Marketing campaigns for `scope` — the `ListLive` reads
  contract (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), built on
  `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION. Campaign is
  non-PII; sort/filter fields are bounded plain attributes. Each page item carries a
  `:send_count` (an `Ash.count` DB aggregate — no send row set is transferred), so
  the count column stays fresh across pagination (it rides the SAME re-read every
  list event runs). On any read error the page is EMPTY — never unbounded.
  """
  def campaigns_page(mount, scope, state) do
    Guard.page(:marketing_campaigns_page, scope, state, fn ->
      page =
        Mount.resource(mount, Campaign)
        |> Ash.Query.ensure_selected([:name, :description, :status, :scheduled_at, :sent_at, :custom])
        |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :description])

      %{page | items: Enum.map(page.items, &Map.put(&1, :send_count, count_sends(mount, scope, &1.id)))}
    end)
  end

  @doc """
  Count the sends for a campaign — a DB aggregate (`Ash.count`), no row set
  transferred (bounded by construction). `0` on any error; `send_count_result/3` tells a failed
  count from a real zero.
  """
  def send_count(mount, scope, campaign_id), do: send_count_result(mount, scope, campaign_id) |> Guard.value(0)

  @doc "Tagged sibling of `send_count/3` (WP6); same contract as `campaigns_result/2`."
  def send_count_result(mount, scope, campaign_id),
    do: Guard.run(:marketing_send_count, scope, fn -> count_sends(mount, scope, campaign_id) end)

  # Raising on purpose: every caller is inside a `Guard.run/3`.
  defp count_sends(mount, scope, campaign_id) do
    Mount.resource(mount, Send)
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.count!(scope: scope)
  end

  @doc "Read a single campaign by id. Non-PII. `{:ok, campaign}` or `:error`."
  def get_campaign(mount, scope, id) do
    case get_campaign_result(mount, scope, id) do
      {:ok, campaign} -> {:ok, campaign}
      {:error, _} -> :error
    end
  end

  @doc """
  Tagged sibling of `get_campaign/3` (WP6): `{:ok, campaign}`, `{:error, :not_found}` for a missing
  (or malformed-id, or denied) record, and `{:error, :unavailable}` ONLY when the read FAILED — a
  failed read is not "Campaign not found."
  """
  def get_campaign_result(mount, scope, id) do
    single_result(:marketing_get_campaign, scope, id, fn uuid ->
      Mount.resource(mount, Campaign)
      |> Ash.Query.ensure_selected([:name, :description, :status, :scheduled_at, :sent_at, :custom])
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read enabled Marketing templates for `scope`, capped at `#{@detail_limit}` rows. Non-PII."
  def templates(mount, scope), do: templates_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `templates/2` (WP6); same contract as `campaigns_result/2`."
  def templates_result(mount, scope) do
    Guard.run(:marketing_templates, scope, fn ->
      Mount.resource(mount, Template)
      |> Ash.Query.ensure_selected([:name, :subject_line, :body_html, :body_text, :from_name, :from_address, :enabled])
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read Marketing segments for `scope`, capped at `#{@detail_limit}` rows (A3
  read-bounding); the Segments page itself reads through the paginated
  `segments_page/3` — this remains only as the compose-page lookup read (the
  send-to-segment select). Non-PII (filter criteria are bounded jsonb).
  """
  def segments(mount, scope), do: segments_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `segments/2` (WP6); same contract as `campaigns_result/2`."
  def segments_result(mount, scope) do
    Guard.run(:marketing_segments, scope, fn ->
      Mount.resource(mount, Segment)
      |> Ash.Query.ensure_selected([:name, :description, :filter_criteria, :subscriber_count, :custom])
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read ONE keyset page of Marketing segments for `scope` — the `ListLive` reads
  contract, built on `Samen.Web.Reads.page!/3` so the read is BOUNDED BY
  CONSTRUCTION. Segment is non-PII; sort/filter fields are bounded plain attributes.
  On any read error the page is EMPTY — never unbounded.
  """
  def segments_page(mount, scope, state) do
    Guard.page(:marketing_segments_page, scope, state, fn ->
      Mount.resource(mount, Segment)
      |> Ash.Query.ensure_selected([:name, :description, :filter_criteria, :subscriber_count, :custom])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :description])
    end)
  end

  @doc "Read a single segment by id. Non-PII. `{:ok, segment}` or `:error`."
  def get_segment(mount, scope, id) do
    case get_segment_result(mount, scope, id) do
      {:ok, segment} -> {:ok, segment}
      {:error, _} -> :error
    end
  end

  @doc "Tagged sibling of `get_segment/3` (WP6); same contract as `get_campaign_result/3`."
  def get_segment_result(mount, scope, id) do
    single_result(:marketing_get_segment, scope, id, fn uuid ->
      Mount.resource(mount, Segment)
      |> Ash.Query.ensure_selected([:name, :description, :filter_criteria, :subscriber_count, :custom])
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  Read all subscribers for `scope`, with `email` (🔒 PII) plane-resolved through
  `Samen.Api.PiiResolution` (tenant clear / operator ••••). Non-recipient status is preserved.
  """
  def subscribers(mount, scope), do: subscribers_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `subscribers/2` (WP6); same contract as `campaigns_result/2`."
  def subscribers_result(mount, scope) do
    Guard.run(:marketing_subscribers, scope, fn ->
      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:email, :status, :consent_at, :source, :custom])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
      |> resolve_pii(mount, Subscriber, scope)
    end)
  end

  @doc """
  Read ONE keyset page of subscribers for `scope` — the bounded-reads contract
  (`Samen.Web.Reads.page!/3`, limit by construction), with `email` (🔒 PII)
  plane-resolved through `Samen.Api.PiiResolution` AFTER paging (tenant clear /
  operator `%Masked{}` → ••••). Sort/filter fields are bounded NON-VAULTED
  attributes only — the vaulted email column is never sorted or filtered (see
  `Samen.Web.Reads` masking notes). On any read error the page is EMPTY — never
  unbounded and never a plaintext downgrade.
  """
  def subscribers_page(mount, scope, state) do
    Guard.page(:marketing_subscribers_page, scope, state, fn ->
      page =
        Mount.resource(mount, Subscriber)
        |> Ash.Query.ensure_selected([:email, :status, :consent_at, :source, :custom])
        |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:source])

      %{page | items: resolve_pii(page.items, mount, Subscriber, scope)}
    end)
  end

  @doc """
  Read the subscribers that make up a segment's audience (ADR-011 §7.2), PII-resolved.
  Phase-4 minimal: a segment targets subscribers by `status` — the segment's
  `filter_criteria["status"]` (default `"active"`) narrows to deliverable recipients. A
  richer criteria language is a follow-up; the audience is always the org's own subscribers.
  """
  def segment_audience(mount, scope, segment),
    do: segment_audience_result(mount, scope, segment) |> Guard.value([])

  @doc "Tagged sibling of `segment_audience/3` (WP6); same contract as `campaigns_result/2`."
  def segment_audience_result(mount, scope, segment) do
    Guard.run(:marketing_segment_audience, scope, fn ->
      status = audience_status(segment)

      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:email, :status, :consent_at, :source, :custom])
      |> Ash.Query.filter(status == ^status)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
      |> resolve_pii(mount, Subscriber, scope)
    end)
  end

  @doc "Read email events for a campaign (delivery/open/click/bounce/…), newest-first. Non-PII."
  def email_events(mount, scope, campaign_id),
    do: email_events_result(mount, scope, campaign_id) |> Guard.value([])

  @doc "Tagged sibling of `email_events/3` (WP6); same contract as `campaigns_result/2`."
  def email_events_result(mount, scope, campaign_id) do
    Guard.run(:marketing_email_events, scope, fn ->
      send_ids =
        Mount.resource(mount, Send)
        |> Ash.Query.ensure_selected([:id, :campaign_id])
        |> Ash.Query.filter(campaign_id == ^campaign_id)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)
        |> Enum.map(& &1.id)

      if send_ids == [] do
        []
      else
        Mount.resource(mount, EmailEvent)
        |> Ash.Query.ensure_selected([:event_type, :occurred_at, :metadata, :send_id, :subscriber_id])
        |> Ash.Query.filter(send_id in ^send_ids)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)
      end
    end)
  end

  @doc """
  Read the sends for a campaign, newest-first (status pills — queued/delivered/…). Non-PII
  (the send row carries only opaque IDs — never the email).
  """
  def sends_for_campaign(mount, scope, campaign_id),
    do: sends_for_campaign_result(mount, scope, campaign_id) |> Guard.value([])

  @doc "Tagged sibling of `sends_for_campaign/3` (WP6); same contract as `campaigns_result/2`."
  def sends_for_campaign_result(mount, scope, campaign_id) do
    Guard.run(:marketing_sends_for_campaign, scope, fn ->
      Mount.resource(mount, Send)
      |> Ash.Query.ensure_selected([:status, :queued_at, :sent_at, :subscriber_id, :campaign_id])
      |> Ash.Query.filter(campaign_id == ^campaign_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Count-by-event_type map for a campaign's email events (for the events summary pills)."
  def event_counts(mount, scope, campaign_id),
    do: event_counts_result(mount, scope, campaign_id) |> Guard.value(%{})

  @doc "Tagged sibling of `event_counts/3` (WP6); same contract as `campaigns_result/2`."
  def event_counts_result(mount, scope, campaign_id) do
    with {:ok, events} <- email_events_result(mount, scope, campaign_id) do
      {:ok, Enum.frequencies_by(events, & &1.event_type)}
    end
  end

  @doc "The active suppression rows for `scope` (opt-outs / bounces), capped at `#{@detail_limit}` rows. Non-PII (opaque subscriber_id)."
  def suppressions(mount, scope), do: suppressions_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `suppressions/2` (WP6); same contract as `campaigns_result/2`."
  def suppressions_result(mount, scope) do
    Guard.run(:marketing_suppressions, scope, fn ->
      Mount.resource(mount, Suppression)
      |> Ash.Query.ensure_selected([:reason, :active, :suppressed_at, :notes, :subscriber_id])
      |> Ash.Query.filter(active == true)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  The subset of `subscriber_ids` that carry an ACTIVE suppression row, as a `MapSet`
  (the Segments page's per-row "suppressed" flag). BOUNDED BY CONSTRUCTION: the read
  is filtered to the given (already page-bounded) ids and limited to their count —
  never a full-table suppression read. Non-PII (opaque ids only).
  """
  def suppressed_ids(mount, scope, subscriber_ids),
    do: suppressed_ids_result(mount, scope, subscriber_ids) |> Guard.value(MapSet.new())

  @doc "Tagged sibling of `suppressed_ids/3` (WP6); same contract as `campaigns_result/2`."
  def suppressed_ids_result(_mount, _scope, []), do: {:ok, MapSet.new()}

  def suppressed_ids_result(mount, scope, subscriber_ids) when is_list(subscriber_ids) do
    Guard.run(:marketing_suppressed_ids, scope, fn ->
      Mount.resource(mount, Suppression)
      |> Ash.Query.ensure_selected([:subscriber_id, :active])
      |> Ash.Query.filter(active == true and subscriber_id in ^subscriber_ids)
      |> Ash.Query.limit(length(subscriber_ids))
      |> Ash.read!(scope: scope)
      |> MapSet.new(& &1.subscriber_id)
    end)
  end

  # ---------------------------------------------------------------------------
  # A3 CRUD — destroys for the list surfaces (creates go through AshPhoenix.Form)
  # ---------------------------------------------------------------------------

  @doc """
  The tenant-ADMIN write scope for the kernel's admin-gated Marketing config writes
  (Campaign / Segment / Template carry `RoleAtLeast :admin`; the mount's plane scope
  is a `:member`, per `Samen.Web.Plane.scope/2`).

  ADR-045 §4.4 (S1a) — delegates to `Samen.Web.TenantRole.admin_scope/3`: the disarmed dev
  posture keeps `:admin` byte-for-byte; an ARMED host derives the principal's REAL
  `Identity.Membership` role (fail-closed `:member`, never `:admin`). The elevation still
  PRESERVES every plane marker (`plane`, `kind`, `impersonation`) from `Mount.scope/2` — an
  operator-plane mount keeps `plane: :operator`, so `Samen.Pii.WriteGuard` (MC-1 / Invariant L1)
  rejects a vaulted-PII write exactly as before, the elevation raises RBAC rank only, and
  `OrgScope` still confines the write to `org_id`. Subscriber writes are member-gated and use the
  plain scope (and the subscriber `email` vault path is unchanged — `add_subscriber/3`).
  """
  def write_scope(mount, org_id, principal \\ nil),
    do: Samen.Web.TenantRole.admin_scope(mount, org_id, principal)

  @doc "Destroy one Marketing campaign for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_campaign(mount, scope, id), do: delete_record(mount, scope, Campaign, id)

  @doc "Destroy one Marketing segment for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_segment(mount, scope, id), do: delete_record(mount, scope, Segment, id)

  # FAIL-HONEST destroy (mirrors `Samen.Web.CRM.Reads.delete_record/4`). ADR-040
  # §5.9 (T37d): Campaign/Segment adopted E6 soft-delete (`archivable true`) — the
  # default `:destroy` is now a soft archive (an UPDATE), so a linked `send` row
  # can no longer FK-refuse it (§5.4: no cascade declared; `send` is not itself
  # archivable). Any OTHER destroy failure (e.g. a policy denial) still surfaces
  # honestly to the caller. The read is `limit(1)` (bounded).
  defp delete_record(mount, scope, name, id) do
    record =
      Mount.resource(mount, name)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      record -> Ash.destroy(record, scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # The send path — consent/suppression enforced (ADR-011 §7.2/§7.3)
  # ---------------------------------------------------------------------------

  @doc """
  Enqueue a send to ONE subscriber, enforcing consent/suppression at the FRAMEWORK layer
  (ADR-011 §7.2). `attrs` carries `subscriber_id`, `org_id`, and optional `campaign_id` /
  `template_id`.

  Order of enforcement (fail-closed):

    1. **Consent / status** — if the subscriber is `:unsubscribed`, `:bounced`, or
       `:complained`, REFUSE (`{:error, :unsubscribed}` etc.). Only an `:active` subscriber
       is deliverable. (A distinct concern from suppression: a subscriber can be undeliverable
       by status with no suppression row.)
    2. **Create the send** via the kernel `Send.:create_checked` action. The kernel enforces
       SUPPRESSION here (an `OrgScope`-inheriting Ash read of this mount's own `Suppression`
       resource — portable across any abbrev, ADR-014 §4) and layers the same-org-FK guard.
       A suppressed recipient is mapped back to `{:error, :suppressed}`. The send row carries
       only opaque IDs — never the email.
    3. **Enqueue** the `Samen.Scopes.Marketing.SendWorker` Oban job with TOKEN-ONLY args
       (`send_id` / `org_id` / `subscriber_id`).

  Returns `{:ok, send}` on success, or `{:error, reason}` (`:suppressed` / a status atom /
  `:not_found` / a changeset) on refusal.
  """
  def enqueue_send(mount, scope, %{subscriber_id: subscriber_id, org_id: org_id} = attrs) do
    with :ok <- refuse_if_undeliverable(mount, scope, subscriber_id),
         {:ok, send} <- create_send(mount, scope, attrs) do
      enqueue_worker(mount, send, org_id, subscriber_id)
      {:ok, send}
    end
  end

  @doc """
  Send a campaign to a whole segment's audience (ADR-011 §7.2). Returns
  `{:ok, [%{subscriber_id, result}]}` where `result` is `{:ok, _}` (queued) or
  `{:error, reason}` (suppressed / undeliverable / `:already_sent`) — so the UI can render
  "queued" vs "suppressed — skipped" per recipient (surfacing the refusal) — or
  `{:error, reason}` when the send could not be run at all (`:campaign_required`,
  `:template_required`, or the exception that stopped the audience read). A failure is NEVER
  folded into an empty result list.

  ## Audience = the segment's real membership

  A `Segment` is a filter-criteria bag (the core models no subscriber-to-segment join), and the
  only criterion it defines is `filter_criteria["status"]` (default `"active"`). The audience is
  EVERY org subscriber matching it — walked with a keyset cursor on `id` in pages of
  `:page_size` (default #{@detail_limit}; the page size bounds each read, NOT the audience), so
  subscriber 201+ is sent just like subscriber 1.

  ## Idempotent per (campaign, subscriber)

  A subscriber that already has a `Send` row for this campaign is reported
  `{:error, :already_sent}` and gets no second row or job, so a repeated submit is a no-op for
  everyone already sent. (The core declares no unique identity on `Send`, so this is a
  read-before-write guard, not a database constraint.)
  """
  def send_campaign_to_segment(mount, scope, campaign, segment, template_id, org_id, opts \\ [])

  def send_campaign_to_segment(_mount, _scope, nil, _segment, _template_id, _org_id, _opts),
    do: {:error, :campaign_required}

  def send_campaign_to_segment(_mount, _scope, _campaign, _segment, template_id, _org_id, _opts)
      when template_id in [nil, ""],
      do: {:error, :template_required}

  def send_campaign_to_segment(mount, scope, campaign, segment, template_id, org_id, opts) do
    page_size = Keyword.get(opts, :page_size, @detail_limit)

    unless is_integer(page_size) and page_size > 0,
      do: raise(ArgumentError, "page_size must be a positive integer, got: #{inspect(page_size)}")

    status = audience_status(segment)

    results =
      Stream.unfold(:start, fn
        :done ->
          nil

        cursor ->
          ids = audience_page(mount, scope, status, cursor, page_size)
          next = if length(ids) < page_size, do: :done, else: List.last(ids)
          if ids == [], do: nil, else: {ids, next}
      end)
      |> Enum.flat_map(fn ids ->
        sent = already_sent_ids(mount, scope, campaign.id, ids)

        Enum.map(ids, fn sub_id ->
          result =
            if MapSet.member?(sent, sub_id) do
              {:error, :already_sent}
            else
              enqueue_send(mount, scope, %{
                subscriber_id: sub_id,
                org_id: org_id,
                campaign_id: campaign.id,
                template_id: template_id
              })
            end

          %{subscriber_id: sub_id, result: result}
        end)
      end)

    {:ok, results}
  rescue
    e ->
      # The audience walk stopped part-way (some recipients may already be queued). Logged by name
      # and cause only; the caller gets a value-free atom, never the exception (its message can
      # interpolate subscriber ids / query values).
      Guard.report(:marketing_send_campaign, scope, e)
      {:error, :audience_unavailable}
  end

  defp audience_page(mount, scope, status, cursor, page_size) do
    query =
      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:id, :status])
      |> Ash.Query.filter(status == ^status)

    query = if cursor == :start, do: query, else: Ash.Query.filter(query, id > ^cursor)

    query
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(page_size)
    |> Ash.read!(scope: scope)
    |> Enum.map(& &1.id)
  end

  defp already_sent_ids(mount, scope, campaign_id, subscriber_ids) do
    Mount.resource(mount, Send)
    |> Ash.Query.ensure_selected([:subscriber_id, :campaign_id])
    |> Ash.Query.filter(campaign_id == ^campaign_id and subscriber_id in ^subscriber_ids)
    |> Ash.Query.limit(length(subscriber_ids))
    |> Ash.read!(scope: scope)
    |> MapSet.new(& &1.subscriber_id)
  end

  @doc """
  Attempt to send to a SPECIFIC list of subscriber ids (used by the compose page's explicit
  recipients, and by tests that need to exercise a suppressed recipient). Returns the same
  per-subscriber result list as `send_campaign_to_segment/6`.
  """
  def send_to_subscribers(mount, scope, subscriber_ids, campaign, template_id, org_id) do
    Enum.map(subscriber_ids, fn sub_id ->
      result =
        enqueue_send(mount, scope, %{
          subscriber_id: sub_id,
          org_id: org_id,
          campaign_id: campaign && campaign.id,
          template_id: template_id
        })

      %{subscriber_id: sub_id, result: result}
    end)
  end

  # ---------------------------------------------------------------------------
  # Prospecting — build a subscriber from a CRM contact's resolved email
  # ---------------------------------------------------------------------------

  @doc """
  Create a `Subscriber` from a CRM contact's email (ADR-011 §7.3 — the "Add to audience"
  path). `email` MUST already be a plaintext string resolved on the TENANT plane (the org
  owns its contacts' PII). The email is written into the subscriber's vault and NEVER stored
  in clear again. Returns `{:ok, subscriber}` or `{:error, reason}`. Refuses a masked email
  (an operator must not enroll a tenant's contact).
  """
  def add_subscriber(mount, scope, %{email: email, org_id: _org_id} = attrs)
      when is_binary(email) do
    create_attrs =
      attrs
      |> Map.take([:org_id, :email, :source, :consent_at])
      |> Map.put_new(:status, :active)
      |> Map.put_new(:source, "crm")

    Mount.resource(mount, Subscriber)
    |> Ash.Changeset.for_create(:create, create_attrs, scope: scope)
    |> Ash.create()
  end

  def add_subscriber(_mount, _scope, %{email: %Samen.Masked{}}),
    do: {:error, :masked_email_refused}

  def add_subscriber(_mount, _scope, _attrs), do: {:error, :invalid_email}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Consent/status gate: only an :active subscriber is deliverable, AND the append-only
  # consent ledger must not have most-recently WITHDRAWN consent. The ledger check is the
  # F3 Unit 1 conjunct: it is the SOURCE OF TRUTH for consent and, being outside the
  # vault, a `:withdrawn` verdict survives a subject crypto-shred — so "do-not-contact"
  # is honored even after the subscriber's PII is erased. Fail-closed: an unresolvable
  # check refuses the send.
  defp refuse_if_undeliverable(mount, scope, subscriber_id) do
    result =
      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:status, :org_id])
      |> Ash.Query.filter(id == ^subscriber_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)

    case result do
      [%{status: :active, org_id: org_id} | _] ->
        refuse_if_consent_withdrawn(mount, org_id, subscriber_id)

      [%{status: status} | _] ->
        {:error, status}

      [] ->
        {:error, :not_found}
    end
  rescue
    e ->
      # Fail-CLOSED (the send is refused, never allowed): the caller renders the refusal per
      # recipient. Logged by name and cause only, so an outage here is not invisible.
      Guard.report(:marketing_deliverability_check, scope, e)
      {:error, :deliverability_check_failed}
  end

  # Derive consent from the ledger (latest-event-wins). A most-recent :withdrawn refuses
  # the send even when the subscriber row's mutable status is still :active.
  defp refuse_if_consent_withdrawn(mount, org_id, subscriber_id) do
    case Samen.Marketing.Consent.state_result(
           Mount.resource(mount, ConsentEvent),
           to_string(org_id),
           to_string(subscriber_id)
         ) do
      {:ok, :withdrawn} -> {:error, :consent_withdrawn}
      {:ok, _state} -> :ok
      # An unreadable ledger is not "no withdrawal on file": the send is refused (fail-closed) and the caller
      # renders the same outage copy as a failed deliverability check, never "consent withdrawn".
      {:error, :unavailable} -> {:error, :deliverability_check_failed}
    end
  end

  # Create the send row through the kernel's suppression-checked action (the only create
  # path on Send). We pass the org_id + subscriber_id as arguments; the kernel enforces
  # SUPPRESSION (portable Ash read on this mount's Suppression resource) and layers its
  # same-org-FK guard. A suppressed recipient surfaces as a changeset error with the
  # "suppressed" message — map it back to {:error, :suppressed} so the UI renders
  # "suppressed — skipped" per recipient.
  defp create_send(mount, scope, attrs) do
    action_attrs = %{
      subscriber_id: attrs.subscriber_id,
      org_id: attrs.org_id,
      campaign_id: Map.get(attrs, :campaign_id),
      template_id: Map.get(attrs, :template_id)
    }

    Mount.resource(mount, Send)
    |> Ash.Changeset.for_create(:create_checked, action_attrs, scope: scope)
    |> Ash.create()
    |> normalize_suppression_error()
  end

  # The kernel refuses a suppressed send by adding a changeset error whose message is
  # exactly "suppressed" (ADR-014 §4). Translate that back to the atom the UI matches on.
  defp normalize_suppression_error({:error, %Ash.Error.Invalid{errors: errors}} = original) do
    if Enum.any?(errors, &(Map.get(&1, :message) == "suppressed")) do
      {:error, :suppressed}
    else
      original
    end
  end

  defp normalize_suppression_error(other), do: other

  # Enqueue the send worker with TOKEN-ONLY args (no email). Best-effort: a missing Oban
  # (e.g. a pure render test) does not fail the send-row creation.
  defp enqueue_worker(_mount, send, org_id, subscriber_id) do
    args = %{"send_id" => send.id, "org_id" => org_id, "subscriber_id" => subscriber_id}

    args
    |> Samen.Scopes.Marketing.SendWorker.new()
    |> Oban.insert()
  rescue
    e ->
      # Best-effort by design: a missing Oban (a pure render test, an un-migrated host) must not
      # fail the send-row creation. Not silent: the failure is logged, by name and cause only.
      Guard.report(:marketing_enqueue_worker, org_id, e)
      :ok
  end

  defp audience_status(%{filter_criteria: %{"status" => status}}) when is_binary(status) do
    case status do
      "active" -> :active
      "unsubscribed" -> :unsubscribed
      "bounced" -> :bounced
      "complained" -> :complained
      _ -> :active
    end
  end

  defp audience_status(_), do: :active

  # Resolve PII fields through the shared chokepoint; resource + repo from the mount.
  # Fail-safe: on any resolver error the fields stay %Masked{} (no plaintext downgrade).
  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:marketing_resolve_pii, scope, e)
      records
  end

  # One record by id: a malformed id is a plain not-found (no read is attempted), an empty
  # result is not-found, a denial is not-found (no existence oracle), and only a FAILED read is
  # `:unavailable`. `read` returns the (<= 1 row) list.
  defp single_result(key, scope, id, read) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rows} <- Guard.run(key, scope, fn -> read.(uuid) end) do
      case rows do
        [record | _] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
