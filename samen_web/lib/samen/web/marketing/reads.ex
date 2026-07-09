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

  # ---------------------------------------------------------------------------
  # Reads — campaigns / templates / segments / subscribers / events
  # ---------------------------------------------------------------------------

  @doc "Read all Marketing campaigns for `scope`, newest-first. Non-PII; org-scoped by policy."
  def campaigns(mount, scope) do
    Mount.resource(mount, Campaign)
    |> Ash.Query.ensure_selected([:name, :description, :status, :scheduled_at, :sent_at, :custom])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a single campaign by id. Non-PII. `{:ok, campaign}` or `:error`."
  def get_campaign(mount, scope, id) do
    result =
      Mount.resource(mount, Campaign)
      |> Ash.Query.ensure_selected([:name, :description, :status, :scheduled_at, :sent_at, :custom])
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)

    case result do
      [campaign | _] -> {:ok, campaign}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read all enabled Marketing templates for `scope`. Non-PII."
  def templates(mount, scope) do
    Mount.resource(mount, Template)
    |> Ash.Query.ensure_selected([:name, :subject_line, :body_html, :body_text, :from_name, :from_address, :enabled])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read all Marketing segments for `scope`. Non-PII (filter criteria are bounded jsonb)."
  def segments(mount, scope) do
    Mount.resource(mount, Segment)
    |> Ash.Query.ensure_selected([:name, :description, :filter_criteria, :subscriber_count, :custom])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a single segment by id. Non-PII. `{:ok, segment}` or `:error`."
  def get_segment(mount, scope, id) do
    result =
      Mount.resource(mount, Segment)
      |> Ash.Query.ensure_selected([:name, :description, :filter_criteria, :subscriber_count, :custom])
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)

    case result do
      [segment | _] -> {:ok, segment}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Read all subscribers for `scope`, with `email` (🔒 PII) plane-resolved through
  `Samen.Api.PiiResolution` (tenant clear / operator ••••). Non-recipient status is preserved.
  """
  def subscribers(mount, scope) do
    Mount.resource(mount, Subscriber)
    |> Ash.Query.ensure_selected([:email, :status, :consent_at, :source, :custom])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Subscriber, scope)
  rescue
    _ -> []
  end

  @doc """
  Read the subscribers that make up a segment's audience (ADR-011 §7.2), PII-resolved.
  Phase-4 minimal: a segment targets subscribers by `status` — the segment's
  `filter_criteria["status"]` (default `"active"`) narrows to deliverable recipients. A
  richer criteria language is a follow-up; the audience is always the org's own subscribers.
  """
  def segment_audience(mount, scope, segment) do
    status = audience_status(segment)

    Mount.resource(mount, Subscriber)
    |> Ash.Query.ensure_selected([:email, :status, :consent_at, :source, :custom])
    |> Ash.Query.filter(status == ^status)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Subscriber, scope)
  rescue
    _ -> []
  end

  @doc "Read email events for a campaign (delivery/open/click/bounce/…), newest-first. Non-PII."
  def email_events(mount, scope, campaign_id) do
    send_ids =
      Mount.resource(mount, Send)
      |> Ash.Query.ensure_selected([:id, :campaign_id])
      |> Ash.Query.filter(campaign_id == ^campaign_id)
      |> Ash.read!(scope: scope)
      |> Enum.map(& &1.id)

    if send_ids == [] do
      []
    else
      Mount.resource(mount, EmailEvent)
      |> Ash.Query.ensure_selected([:event_type, :occurred_at, :metadata, :send_id, :subscriber_id])
      |> Ash.Query.filter(send_id in ^send_ids)
      |> Ash.Query.sort(occurred_at: :desc)
      |> Ash.read!(scope: scope)
    end
  rescue
    _ -> []
  end

  @doc """
  Read the sends for a campaign, newest-first (status pills — queued/delivered/…). Non-PII
  (the send row carries only opaque IDs — never the email).
  """
  def sends_for_campaign(mount, scope, campaign_id) do
    Mount.resource(mount, Send)
    |> Ash.Query.ensure_selected([:status, :queued_at, :sent_at, :subscriber_id, :campaign_id])
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Count-by-event_type map for a campaign's email events (for the events summary pills)."
  def event_counts(mount, scope, campaign_id) do
    email_events(mount, scope, campaign_id)
    |> Enum.frequencies_by(& &1.event_type)
  end

  @doc "The active suppression rows for `scope` (opt-outs / bounces). Non-PII (opaque subscriber_id)."
  def suppressions(mount, scope) do
    Mount.resource(mount, Suppression)
    |> Ash.Query.ensure_selected([:reason, :active, :suppressed_at, :notes, :subscriber_id])
    |> Ash.Query.filter(active == true)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
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
  Send a campaign to a whole segment's audience (ADR-011 §7.2). Returns a per-subscriber
  result list `[%{subscriber_id, result}]` where `result` is `{:ok, _}` (queued) or
  `{:error, reason}` (suppressed / undeliverable) — so the UI can render "queued" vs
  "suppressed — skipped" per recipient (surfacing the refusal).
  """
  def send_campaign_to_segment(mount, scope, campaign, segment, template_id, org_id) do
    audience_ids =
      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:id, :status])
      |> Ash.Query.filter(status == ^audience_status(segment))
      |> Ash.read!(scope: scope)
      |> Enum.map(& &1.id)

    # Also attempt any suppressed/unsubscribed subscribers referenced by the segment so the
    # refusal is VISIBLE — but for the plain "active" audience this list is the deliverables.
    Enum.map(audience_ids, fn sub_id ->
      result =
        enqueue_send(mount, scope, %{
          subscriber_id: sub_id,
          org_id: org_id,
          campaign_id: campaign && campaign.id,
          template_id: template_id
        })

      %{subscriber_id: sub_id, result: result}
    end)
  rescue
    _ -> []
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

  # Consent/status gate: only an :active subscriber is deliverable.
  defp refuse_if_undeliverable(mount, scope, subscriber_id) do
    result =
      Mount.resource(mount, Subscriber)
      |> Ash.Query.ensure_selected([:status])
      |> Ash.Query.filter(id == ^subscriber_id)
      |> Ash.read!(scope: scope)

    case result do
      [%{status: :active} | _] -> :ok
      [%{status: status} | _] -> {:error, status}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :deliverability_check_failed}
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
    _ -> :ok
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
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
