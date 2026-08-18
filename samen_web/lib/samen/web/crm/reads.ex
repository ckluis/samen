defmodule Samen.Web.CRM.Reads do
  @moduledoc """
  The framework CRM read layer for the inherited CRM pages (companies, contacts, pipeline).

  Promoted from the driftwood-local `Driftwood.CrmReads` (ADR-009 §3.3): the SAME functions,
  but every hardcoded host module becomes `Samen.Web.Mount.resource(mount, Name)` and every
  `repo: Driftwood.Repo` becomes `repo: mount.repo`. So the same code reads Driftwood's CRM
  inside Driftwood, PawChart's CRM inside PawChart — no LiveView or reads function names a
  host module.

  All reads go through Ash so OrgScope + vault masking apply. PII fields on the CRM `Person`
  (full_name / emails / phones) are resolved through `Samen.Api.PiiResolution.resolve/4`:

    * on `plane: :tenant` (the org's own console) the org reads its OWN contacts'
      name/email/phone in CLEAR — no reveal grant needed (tenant-as-owner rule);
    * on `plane: :operator` (impersonation) the SAME fields render `%Masked{}` (→ ••••)
      by construction of the resolver.

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a vault token out
  of a `%Masked{}`, and NEVER introduces a "show plaintext" code path. Plaintext only
  reaches the LiveView if the PiiResolution resolver already resolved it through the shared
  chokepoint. A resolver failure keeps `%Masked{}` (no plaintext downgrade).
  """

  require Ash.Query
  import Ash.Expr

  alias Samen.Web.Mount
  alias Samen.Web.ObjectRef

  # A3 read-bounding (WS-A design §1.1 "read! elimination"): every non-page read on the
  # CRM surfaces carries an explicit limit. Detail sub-lists (a company's contacts, a
  # person's timeline, …) are bounded to the kit's hard page cap rather than paginated —
  # they are single-parent fan-outs, not hot lists.
  @detail_limit 200

  # The Work Task fields the CRM detail timeline projects onto its entry map (ADR-041 §6.1:
  # kind → :type, title → :subject, completed_at||inserted_at → :at, custom["author"] → :who).
  @timeline_fields [:kind, :title, :body, :status, :due_at, :completed_at, :custom, :subject_key, :subject_id]

  # The Mailbox `MailMessage` fields the CRM detail timeline projects (T74 §I1). The
  # first three are 🔒 vault-routed and MUST be explicitly selected — otherwise the
  # PiiResolution pass has nothing to resolve and the timeline silently loses them.
  @mail_fields [
    :subject,
    :body,
    :counterparty_address,
    :direction,
    :occurred_at,
    :subject_key,
    :subject_id,
    :company_id
  ]

  # The Mailbox `Connection` fields the CRM mailbox settings surface reads (🔒 address).
  @connection_fields [:address, :provider, :status, :last_synced_at, :external_account_id]

  @doc """
  Read CRM companies for `scope` — non-PII; org-scoped by policy. BOUNDED to
  `#{@detail_limit}` rows (A3 read-bounding); the Companies page itself reads through
  the paginated `companies_page/3` — this remains only as the lookup read (e.g. the
  contact form's company select / the contacts list's company-name map).
  """
  def companies(mount, scope) do
    Mount.resource(mount, Company)
    |> Ash.Query.ensure_selected([:name, :industry, :size, :custom])
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of CRM companies for `scope` — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), built on
  `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION. Company is
  non-PII; sort/filter fields are bounded plain attributes. On any read error the
  page is EMPTY — never unbounded.
  """
  def companies_page(mount, scope, state) do
    Mount.resource(mount, Company)
    |> Ash.Query.ensure_selected([:name, :domain, :industry, :size, :website, :custom])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name, :industry])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read all CRM people (contacts) for `scope`, with PII (full_name/emails/phones)
  plane-resolved through `Samen.Api.PiiResolution` (tenant clear / operator ••••).
  """
  def contacts(mount, scope) do
    Mount.resource(mount, Person)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id, :custom])
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Person, scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of CRM contacts for `scope` — the A2 `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3). Built on
  `Samen.Web.Reads.page!/3`, so the read is BOUNDED BY CONSTRUCTION
  (`limit(page_size + 1)`, hostile page sizes clamped) and keyset-stable under
  concurrent inserts. PII (full_name/emails/phones) is plane-resolved through
  `Samen.Api.PiiResolution` AFTER paging — tenant clear / operator `%Masked{}` (••••).

  Sort/filter fields are bounded, NON-VAULTED attributes (`display_name`/`job_title`);
  the vaulted columns are never sorted or filtered (see `Samen.Web.Reads` masking notes).
  On any read error the page is EMPTY, never unbounded and never a plaintext downgrade.

  ADR-040 §5.8 (T37h) — `state.show_archived` (the `Samen.Web.ListLive` archived-
  filter toggle) switches to the `:archived` read (Person IS `archivable: true`,
  T37c) — a TRASH view (`Samen.Archival.OnlyArchived`; archived rows ONLY, not a
  union with the live set): "View: live | archived", a filter switch. Masking is
  UNCHANGED either way: `resolve_pii/4` still runs on every item AFTER paging, so an
  archived Person's `full_name`/`emails`/`phones` resolve through
  `Samen.Api.PiiResolution` on the actor's plane exactly like a live row's — clear on
  tenant, `%Masked{}` (••••) on operator-without-grant. Archiving never bypasses the
  resolver.
  """
  def contacts_page(mount, scope, state) do
    base = Mount.resource(mount, Person)
    base = if state.show_archived, do: Ash.Query.for_read(base, :archived), else: base

    page =
      base
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom,
        :archived_at
      ])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:display_name, :job_title])

    %{page | items: resolve_pii(page.items, mount, Person, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read ONE keyset page of CRM contacts as a GALLERY page (G5, WS-G — the FIRST client of
  `Samen.UI.gallery/1`). The SAME bounded, PII-resolved `%Samen.Web.Page{}` as
  `contacts_page/3`, but sorted by `:id` (ASC) so the keyset cursor is a single NON-PII opaque
  uuid — serializable as the gallery's no-JS `?after=<id>` link (`display_name` would leak into
  the URL; `id` never does). `after_id` is the `?after=` param (`nil` = the first page); it
  becomes the keyset cursor `{after_id}`. Built on `Samen.Web.Reads.page!/3`, so the read is
  BOUNDED BY CONSTRUCTION and keyset-stable under concurrent inserts. PII
  (full_name/emails/phones) is plane-resolved AFTER paging — tenant clear / operator
  `%Masked{}` (••••). On any read error the page is EMPTY, never unbounded, never a plaintext
  downgrade.

  `opts`:

    * `:page_size` — the gallery card-page size (default `12`; clamped by `page!/3`).
  """
  def contacts_gallery(mount, scope, after_id, opts \\ []) do
    size = Samen.Web.Reads.bounded_page_size(Keyword.get(opts, :page_size, 12))
    cursor = if after_id in [nil, ""], do: nil, else: {after_id}
    state = %Samen.Web.ListState{sort: {:id, :asc}, cursor: cursor, page_size: size}

    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom
      ])
      |> Samen.Web.Reads.page!(state, scope: scope)

    %{page | items: resolve_pii(page.items, mount, Person, scope)}
  rescue
    _ ->
      %Samen.Web.Page{
        items: [],
        page_size: Samen.Web.Reads.bounded_page_size(Keyword.get(opts, :page_size, 12))
      }
  end

  @doc """
  Read a single CRM person (contact) by id for `scope`, with PII plane-resolved
  (tenant clear / operator ••••). `{:ok, person}` or `:error`. **This is the new
  PII surface** (ADR-011 §5 — the masking-test target).
  """
  def get_contact(mount, scope, id) do
    result =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom
      ])
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> resolve_pii(mount, Person, scope)

    case result do
      [person | _] -> {:ok, person}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read a single CRM company by id for `scope`. Non-PII. `{:ok, company}` or `:error`."
  def get_company(mount, scope, id) do
    result =
      Mount.resource(mount, Company)
      |> Ash.Query.ensure_selected([:name, :domain, :industry, :size, :website, :notes, :custom])
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)

    case result do
      [company | _] -> {:ok, company}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  T160 (spec §I4 completion) — set/clear this company's `billing_customer_id` anchor,
  the authoritative CRM-`Company` <-> tenant `Billing.Customer` link
  (`Samen.CRM.AccountLink`). Registers the Tier-1 custom field for this org first
  (idempotent, zero migration — `AccountLink.ensure_registered!/3`, the ADR-041
  `crm_refs` precedent), then writes through the ordinary sanctioned `:update` action
  (org-scoped + the Tier-1 custom-bag validator — no bypass). `id` blank/nil CLEARS the
  anchor (the link then falls back to the fail-closed domain match, or honest absence).
  `{:ok, company}` or `{:error, reason}`.
  """
  def link_billing_customer(mount, scope, company, id) do
    with org_id when is_binary(org_id) <- scope_org_id(scope) do
      company_resource = Mount.resource(mount, Company)
      :ok = Samen.CRM.AccountLink.ensure_registered!(org_id, company_resource, mount.repo)

      value = if is_binary(id) and String.trim(id) != "", do: String.trim(id), else: nil
      custom = Map.put(company.custom || %{}, Samen.CRM.AccountLink.anchor_field(), value)

      # `org_id` is included explicitly (a same-value no-op write): `get_company/3`
      # doesn't SELECT it (non-PII detail reads never needed it before), so
      # `changeset.data.org_id` would otherwise be `Ash.NotLoaded` — and
      # `Samen.CustomFields.Change`'s validator reads `org_id` straight off the
      # changeset/data (not the scope) to resolve the Tier-1 field's tenant boundary.
      company
      |> Ash.Changeset.for_update(:update, %{custom: custom, org_id: org_id}, scope: scope)
      |> Ash.update()
    else
      _ -> {:error, :no_org}
    end
  rescue
    e -> {:error, e}
  end

  defp scope_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp scope_org_id(_scope), do: nil

  @doc "Read this company's contacts (people) for `scope`, PII plane-resolved. Optional (ADR-011 §4.2)."
  def contacts_for_company(mount, scope, company_id) do
    Mount.resource(mount, Person)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title, :company_id])
    |> Ash.Query.filter(company_id == ^company_id)
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Person, scope)
  rescue
    _ -> []
  end

  @doc """
  Read a person's activity timeline, newest-first. Non-PII (bounded fields + an
  object-ref anchor). ADR-041 §6.1: the CRM Activity was migrated into the canonical
  Work-scope `Task`; this reads Task filtered by the generic `(subject_key, subject_id)`
  anchor for `crm.person` **OR** the preserved multi-anchor set in
  `custom.crm_refs.person_id` — so a task that a migrated multi-anchored Activity
  produced still appears in BOTH the person and company timelines (zero timeline loss).
  """
  def activities_for_person(mount, scope, person_id) do
    person_id = to_string(person_id)

    work_task_resource(mount)
    |> Ash.Query.ensure_selected(@timeline_fields)
    |> Ash.Query.filter(
      (subject_key == "crm.person" and subject_id == ^person_id) or
        get_path(custom, ["crm_refs", "person_id"]) == ^person_id
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a company's activity timeline, newest-first (Work `Task`, anchored to `crm.company`). Non-PII."
  def activities_for_company(mount, scope, company_id) do
    company_id = to_string(company_id)

    work_task_resource(mount)
    |> Ash.Query.ensure_selected(@timeline_fields)
    |> Ash.Query.filter(
      (subject_key == "crm.company" and subject_id == ^company_id) or
        get_path(custom, ["crm_refs", "company_id"]) == ^company_id
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read a company's opportunities with its pipeline stage joined. Non-PII (ADR-011 §5).
  Each row gets a `:__stage__` (the `Pipeline` row) for a stage pill.
  """
  def opportunities_for_company(mount, scope, company_id) do
    opps =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected([:name, :value, :status, :pipeline_id, :company_id, :close_date])
      |> Ash.Query.filter(company_id == ^company_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    stage_by_id =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
      |> Map.new(fn s -> {s.id, s} end)

    Enum.map(opps, fn opp -> Map.put(opp, :__stage__, Map.get(stage_by_id, opp.pipeline_id)) end)
  rescue
    _ -> []
  end

  @doc """
  Log an activity as a canonical Work `Task` (ADR-041 §5/§6.1 — Activity migrated into
  Task). `attrs` carries the composer fields (`type`/`subject`/`body`, or their Task
  names `kind`/`title`), one of `person_id`/`company_id`/`opportunity_id`, `status`,
  `completed_at`, and `org_id`.

  ## Cross-org enforcement (the SameOrgFk replacement, ADR-041 §6.1)

  Task's subject is a generic `(subject_key, subject_id)` pointer, NOT a `belongs_to` —
  so `SameOrgFk` cannot target it. The invariant is instead enforced at the WRITE
  boundary by the **org-scoped `Samen.Web.ObjectRef.resolve/3`**: the CRM subject ref is
  resolved with the viewer's scope, so a cross-org id returns `{:error, :not_found}`
  (`OrgScope` narrows the read to the actor's org) and the task is never anchored to
  another org's object — INERT by construction, not a SameOrgFk validation error. The
  Task create then rides the standard OrgScope + `RoleAtLeast(:member)` gate (this module
  adds NO policy of its own). `{:ok, task}` or `{:error, reason}`.
  """
  def create_activity(mount, scope, attrs) do
    with {:ok, {subject_key, subject_id}} <- resolve_crm_subject(mount, scope, attrs),
         task_mod when is_atom(task_mod) and not is_nil(task_mod) <- work_task_resource(mount) do
      # NOTE: custom.crm_refs is a MIGRATION-only preservation bag (written by the raw-SQL
      # migrate_activity_to_task migration, which bypasses the Tier-1 custom-bag guard). A
      # new single-anchor task carries only the primary `(subject_key, subject_id)` anchor —
      # writing an unregistered `crm_refs` key through Ash is refused by the custom-bag guard.
      task_attrs =
        attrs
        |> activity_to_task_attrs()
        |> Map.merge(%{subject_key: subject_key, subject_id: subject_id})

      task_mod
      |> Ash.Changeset.for_create(:create, task_attrs, scope: scope)
      |> Ash.create()
    else
      nil -> {:error, :work_scope_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Destroy one CRM person for `scope` (A3 CRUD wiring — the contacts delete). The write
  goes through Ash so OrgScope applies (a cross-org id is not even fetched); this module
  adds NO policy of its own. `:ok` or `{:error, reason}`.
  """
  def delete_contact(mount, scope, id), do: delete_record(mount, scope, Person, id)

  @doc "Destroy one CRM company for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_company(mount, scope, id), do: delete_record(mount, scope, Company, id)

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

  @doc """
  Read the CRM contacts that are LEADS — `person.custom["lifecycle_stage"]` in the given
  bounded set (ADR-011 §8 prospecting lens). PII (name/email/phone) is plane-resolved
  (tenant clear / operator ••••), same as `contacts/2`. `stages` is a list of stage strings
  (default the early-funnel `["lead", "mql", "sql"]`). BOUNDED via `contacts/2`'s limit;
  the Leads page itself reads through the paginated `leads_page/3`.
  """
  def leads(mount, scope, stages \\ ~w(lead mql sql)) do
    stage_set = MapSet.new(stages)

    contacts(mount, scope)
    |> Enum.filter(fn p ->
      case p.custom do
        %{"lifecycle_stage" => stage} when is_binary(stage) -> MapSet.member?(stage_set, stage)
        _ -> false
      end
    end)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of CRM LEADS for `scope` — the `ListLive` reads contract over the
  early-funnel lens (A3: the Leads page's `read!` elimination). The lifecycle filter is
  applied SERVER-SIDE on the Tier-1 `custom` jsonb bag (`get_path(custom,
  ["lifecycle_stage"]) in stages`) BEFORE the keyset window, so the page is bounded by
  construction AND complete (an Elixir post-filter over a limited read would drop rows).
  PII (name/email/phone) is plane-resolved AFTER paging — tenant clear / operator
  `%Masked{}` (••••). On any read error the page is EMPTY, never a plaintext downgrade.
  """
  def leads_page(mount, scope, state, stages \\ ~w(lead mql sql)) do
    page =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([
        :full_name,
        :emails,
        :phones,
        :display_name,
        :job_title,
        :company_id,
        :custom
      ])
      |> Ash.Query.filter(expr(get_path(custom, ["lifecycle_stage"]) in ^stages))
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:display_name, :job_title])

    %{page | items: resolve_pii(page.items, mount, Person, scope)}
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc """
  Read CRM opportunities grouped by pipeline stage for `scope`. Non-PII. BOUNDED to
  `#{@detail_limit}` rows per read (A3 read-bounding, AC-G1-5): the kanban board is a
  grouped render, not a keyset list, so it takes the hard cap — an org with more open
  opportunities than the cap sees the oldest `#{@detail_limit}` on the board, never an
  unbounded row transfer.
  """
  def pipeline(mount, scope) do
    opps =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected([:name, :value, :status, :pipeline_id, :company_id, :close_date])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    stages =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.Query.sort(stage_order: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    stage_by_id = Map.new(stages, fn s -> {s.id, s} end)

    opps_by_stage =
      Enum.group_by(opps, fn opp ->
        case Map.get(stage_by_id, opp.pipeline_id) do
          nil -> %{name: "unknown", label: "Unknown", stage_order: 99}
          stage -> stage
        end
      end)

    stages
    |> Enum.map(fn stage ->
      stage_opps = Map.get(opps_by_stage, stage, [])
      %{stage: stage, opportunities: stage_opps}
    end)
    |> Enum.filter(fn %{opportunities: o} -> length(o) > 0 end)
  rescue
    _ -> []
  end

  # The non-PII Opportunity fields a pipeline card renders.
  @opp_card_fields [:name, :value, :status, :pipeline_id, :company_id, :close_date]

  @doc """
  Build the CRM Pipeline KANBAN board (T51, G1 — the FIRST client of the generic
  `Samen.Web.Reads.group_by!/3`, T50). Groups Opportunities by their `:pipeline_id` stage
  into an ORDERED, per-column-BOUNDED `%Samen.Web.Board{}` whose columns are the org's
  Pipeline stages in `stage_order`.

  This is the THIN vertical wiring: it reads the stage config rows (org-scoped, bounded)
  to name the ordered `{pipeline_id, stage_label}` columns, then delegates ALL grouping,
  per-column bounding, exact counts, and org-scoping to `group_by!/3` — it re-implements
  none of that. Opportunities are NON-PII (no vault field on a card), so no PII resolution
  is needed; the board never plaintext-downgrades regardless.

  Returns `%{board: %Board{}, stages: [stage]}` — `stages` lets the caller render a
  stage-type pill in the column header (thin, header-only metadata). On any read error the
  board is EMPTY (`groups: []`), never an unbounded read.

  `opts`:

    * `:per_group_limit` — per-column card cap forwarded to `group_by!/3` (default the
      framework group cap). The board is bounded by construction either way.
  """
  def pipeline_board(mount, scope, opts \\ []) do
    cap = Keyword.get(opts, :per_group_limit, Samen.Web.Reads.default_group_cap())

    stages =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order, :stage_type])
      |> Ash.Query.sort(stage_order: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    columns = Enum.map(stages, fn s -> {s.id, s.label || s.name} end)

    board =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected(@opp_card_fields)
      |> Samen.Web.Reads.group_by!(:pipeline_id,
        scope: scope,
        groups: columns,
        per_group_limit: cap,
        row_sort: {:id, :asc}
      )

    %{board: board, stages: stages}
  rescue
    _ -> %{board: %Samen.Web.Board{groups: [], group_field: :pipeline_id}, stages: []}
  end

  @doc """
  Build the CRM opportunity CALENDAR board (T52, G2 — the FIRST client of the generic
  `Samen.Web.Reads.calendar_by_day!/3`). Windows Opportunities by their `:close_date` into an
  ORDERED, per-DAY-BOUNDED `%Samen.Web.Board{}` (one day-keyed column per calendar day of the
  month), for rendering through `Samen.UI.calendar/1`.

  This is the THIN vertical wiring: it names the resource (`Opportunity`), the date facet
  (`:close_date`), and the month window, then delegates ALL windowing, per-day bounding, exact
  counts, org-scoping, and the vault-field refusal to `calendar_by_day!/3` — it re-implements
  none of that. Opportunities are NON-PII (no vault field on an event), so no PII resolution
  is needed; the board never plaintext-downgrades regardless.

  `month` is any `Date` in the month to render. On any read error the board is EMPTY
  (`groups: []`), never an unbounded read.

  `opts`:

    * `:per_group_limit` — per-DAY event cap forwarded to `calendar_by_day!/3` (default the
      framework calendar cap). The calendar is bounded by construction either way.
  """
  def opportunity_calendar(mount, scope, month, opts \\ []) do
    cap = Keyword.get(opts, :per_group_limit, Samen.Web.Reads.default_calendar_cap())

    board =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.ensure_selected(@opp_card_fields)
      |> Samen.Web.Reads.calendar_by_day!(:close_date,
        scope: scope,
        month: month,
        per_group_limit: cap,
        row_sort: {:id, :asc}
      )

    %{board: board, month: Samen.UI.Calendar.first_of_month(month)}
  rescue
    _ -> %{board: %Samen.Web.Board{groups: [], group_field: :close_date}, month: Samen.UI.Calendar.first_of_month(month)}
  end

  @doc """
  Read the NEXT keyset page of Opportunities for ONE pipeline stage column — the board's
  per-column "load more" (T51, AC constraint (e)). `stage_key` is the column's `pipeline_id`
  (a string; `""` or `nil` = the uncategorized/`NULL`-stage column); `cursor` is the
  `%Board.Group{}`'s `next_cursor` (the keyset position after its last loaded card).

  Built on `Samen.Web.Reads.page!/3`, so the read is BOUNDED BY CONSTRUCTION and org-scoped
  (OrgScope narrows to the actor's org — a forged cross-org `stage_key` matches nothing).
  Same `{:id, :asc}` sort as `pipeline_board/3`, so the cursor lines up. On any read error
  the page is EMPTY, never unbounded. Returns a `%Samen.Web.Page{}`.
  """
  def pipeline_stage_page(mount, scope, stage_key, cursor, opts \\ []) do
    size = Keyword.get(opts, :per_group_limit, Samen.Web.Reads.default_group_cap())
    state = %Samen.Web.ListState{cursor: cursor, sort: {:id, :asc}, page_size: size}

    Mount.resource(mount, Opportunity)
    |> Ash.Query.ensure_selected(@opp_card_fields)
    |> stage_filter(stage_key)
    |> Samen.Web.Reads.page!(state, scope: scope)
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(nil)}
  end

  defp stage_filter(query, key) when key in [nil, ""],
    do: Ash.Query.filter(query, is_nil(pipeline_id))

  defp stage_filter(query, key),
    do: Ash.Query.filter(query, pipeline_id == ^key)

  @doc """
  Non-PII count/sum metrics for the CRM summary cards. Computed as DB aggregates
  (`Ash.count`/`Ash.sum`) — no row set is ever transferred, so the read is bounded by
  construction (A3 read-bounding: this replaced an unbounded open-opportunities `read!`).
  """
  def metrics(mount, scope) do
    open_opps_query =
      Mount.resource(mount, Opportunity)
      |> Ash.Query.filter(status == :open)

    %{
      companies: count_resource(Mount.resource(mount, Company), scope),
      contacts: count_resource(Mount.resource(mount, Person), scope),
      open_opps: count_resource(open_opps_query, scope),
      # ADR-036 §4.5(3): value_cents was dropped by the H1 Money migration;
      # :value sums as a Money composite via ash_money's Postgres sum aggregate.
      pipeline_value: sum_resource(open_opps_query, :value, scope)
    }
  end

  @doc """
  Total pipeline value (minor units) across ALL of the org's opportunities, as a DB `sum`
  aggregate — no row transfer, bounded by construction. Powers the pipeline header's value
  metric without loading the (per-column-capped) board rows. `0` on any error.
  """
  def pipeline_value_cents(mount, scope) do
    case Ash.sum!(Mount.resource(mount, Opportunity), :value, scope: scope) do
      %Money{} = money -> Samen.Type.Money.cents(money)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # The bounded Opportunity status domain (blueprint `one_of`) → dashboard slice labels.
  @opp_statuses [{:open, "Open"}, {:won, "Won"}, {:lost, "Lost"}, {:on_hold, "On hold"}]

  @doc """
  Build the CRM DASHBOARD aggregates (T56, G8 — the FIRST client of the generic
  `Samen.Web.Reads.aggregate_by!/3` + `time_series!/3`). Returns a map of `%Samen.Web.Series{}`
  for the dashboard tiles plus the reused stat metrics — ALL org-scoped, DB-computed (no row
  transfer), and bounded:

    * `:value_by_stage` — pipeline `value` SUMMED per stage (a bar breakdown; `{:sum, :value}`
      over `:pipeline_id`, slices = the org's ordered stages).
    * `:by_status` — opportunity COUNT per status (a pie; `:count` over `:status`, the bounded
      status enum as slices).
    * `:closing_over_time` — opportunity COUNT bucketed by `:close_date` month over the window
      (a line series; bounded buckets).
    * `:stats` — the reused `metrics/2` (companies/contacts/open_opps/pipeline_value) stat tiles.
    * `:rates` — `pipeline_rates/2` (T76/I3): `%{win_rate:, conversion_rate:, won:, lost:,
      open:, on_hold:}` — see that function's doc for the two rates' EXPLICIT, DIFFERENT
      denominators. Either rate is `nil` (never a fabricated `0.0`) when its denominator is 0.
    * `:leaderboard` — `activity_leaderboard/3` (T76/I3): `%{rows: [%{rank:, owner_id:,
      count:}], capped:, shown:, hidden_owners:, hidden_count:}`, ranking org members by
      CRM-anchored activity volume, RANKED BEFORE CAPPED (fix round 1, MED-1 — the true top
      performer always surfaces regardless of uuid sort order). `rows: []` when the org has no
      owned CRM activities yet (honest empty, never fabricated rows).

  This is the THIN vertical wiring: it names the resource (`Opportunity`), the facets
  (`:pipeline_id` / `:status` / `:close_date`) and the measures, then delegates ALL discovery,
  per-slice SQL aggregation, org-scoping, bucket bounding, and the vault-field refusals to the
  framework primitives — it re-implements none of that. Opportunities are NON-PII (no vault
  field), so the aggregated facets are non-secret by construction (verified in the tests
  against the vaulted `Person.full_name` anchor). On any read error a tile is an EMPTY series,
  never an unbounded read.

  `opts`:

    * `:months` — the trailing window length for `:closing_over_time` (default `6`).
    * `:today` — the window anchor `Date` (default `Date.utc_today/0`).
  """
  def crm_dashboard(mount, scope, opts \\ []) do
    stages =
      Mount.resource(mount, Pipeline)
      |> Ash.Query.ensure_selected([:name, :label, :stage_order])
      |> Ash.Query.sort(stage_order: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    stage_cols = Enum.map(stages, fn s -> {s.id, s.label || s.name} end)

    months = Keyword.get(opts, :months, 6)
    today = Keyword.get(opts, :today, Date.utc_today())
    range_start = today |> Date.beginning_of_month() |> add_months(-(months - 1))
    range_end = today |> Date.beginning_of_month() |> add_months(1)

    %{
      value_by_stage: value_by_stage(mount, scope, stage_cols),
      by_status: opportunities_by_status(mount, scope),
      closing_over_time: opportunities_over_time(mount, scope, range_start, range_end),
      stats: metrics(mount, scope),
      # T76/I3 — conversion + win-rate + the activity leaderboard, folded into the SAME
      # dashboard aggregate so one `crm_dashboard/3` call powers every G8 tile.
      rates: pipeline_rates(mount, scope),
      leaderboard: activity_leaderboard(mount, scope)
    }
  end

  # ---------------------------------------------------------------------------
  # T76/I3 — CRM reporting: conversion, win-rate, activity leaderboard (G8, T56 kit)
  # ---------------------------------------------------------------------------

  @doc """
  Pipeline WIN-RATE + CONVERSION-RATE (T76/I3) — two DISTINCT, EXPLICITLY-DEFINED rates
  computed over the SAME per-status counts `opportunities_by_status/2` already computes (no
  extra query — numerically consistent with the dashboard's status pie by construction).

  ## Denominators (the definition a reader must be able to find HERE — spec I3's "define the
  denominators explicitly" instruction)

    * `:win_rate` — the CLOSED-DEALS basis: `won / (won + lost)`. Open and on-hold
      opportunities are excluded from BOTH the numerator and the denominator — a rate over
      DECIDED deals only (the deal-desk convention: "of the deals we've finished fighting
      for, how many did we win").
    * `:conversion_rate` — the ALL-CREATED basis: `won / (open + won + lost + on_hold)`.
      EVERY opportunity the org has ever created counts in the denominator, including ones
      still open — this tracks "what fraction of everything that ever entered the pipeline
      eventually won", a wider, slower-moving number than `:win_rate` by design (an org with
      a large open pipeline and a high win_rate can still have a low conversion_rate simply
      because most deals haven't been decided yet — that is NOT a bug, it is the two
      denominators disagreeing on purpose).

  ## Honest-empty (never a fabricated rate)

  Both rates are `nil` — NOT `0.0` — when their denominator is `0` (an org with no closed
  deals has no win_rate; an org with no opportunities at all has no conversion_rate). A
  fabricated `0%` would read as "we lose every deal", which is false when the truth is
  "no deals have been decided yet". The caller renders `nil` as "—", never as a number.

  Returns `%{win_rate:, conversion_rate:, won:, lost:, open:, on_hold:}` — the raw per-status
  counts ride along so a caller can render "12 won / 30 closed" alongside the percentage.
  """
  def pipeline_rates(mount, scope) do
    counts =
      mount
      |> opportunities_by_status(scope)
      |> Map.get(:points)
      |> Map.new(fn point -> {point.key, round_count(point.value)} end)

    won = Map.get(counts, :won, 0)
    lost = Map.get(counts, :lost, 0)
    open = Map.get(counts, :open, 0)
    on_hold = Map.get(counts, :on_hold, 0)

    %{
      win_rate: rate(won, won + lost),
      conversion_rate: rate(won, won + lost + open + on_hold),
      won: won,
      lost: lost,
      open: open,
      on_hold: on_hold
    }
  rescue
    _ -> %{win_rate: nil, conversion_rate: nil, won: 0, lost: 0, open: 0, on_hold: 0}
  end

  defp rate(_won, 0), do: nil
  defp rate(won, total), do: won / total

  defp round_count(n) when is_integer(n), do: n
  defp round_count(n) when is_float(n), do: round(n)
  defp round_count(_), do: 0

  # The CRM object-ref subject keys a logged activity anchors to (ADR-041 §6.1) — the
  # leaderboard counts ONLY these, so an org's OTHER Work-scope tasks (a project checklist
  # item, a freight check-call, …) never inflate a CRM activity count.
  @crm_subject_keys ~w(crm.company crm.person crm.opportunity)

  @doc """
  Activity LEADERBOARD (T76/I3) — ranks org members by the count of CRM-anchored activities
  (Work `Task` rows whose `subject_key` is one of `#{inspect(@crm_subject_keys)}`) they OWN
  (`Task.owner_id`). Built on the SAME generic `Samen.Web.Reads.aggregate_by!/3` primitive the
  G8 dashboard's other tiles use (T56): the per-owner count is a DB `Ash.count!`, org-scoped
  (`Samen.Policy.OrgScope`, unconditional — see `aggregate_by!/3`'s own doc).

  ## `owner_id` carries NO PII — this surface resolves nothing through the vault (verified,
  refutable)

  `Task.owner_id` is a plain, structurally NON-VAULTED uuid — `samen_core/lib/samen/scopes/
  work/blueprint.ex`'s moduledoc states this directly ("PII map — EMPTY (INV-1)… owner_id…
  structurally non-PII") and, BY ANALOGY to ADR-041 §4.1's CRM `subject_key`/`subject_id`
  ruling (which itself governs avoiding a CRM FK, not Identity coupling specifically), that
  same blueprint moduledoc explains why `owner_id` is a plain uuid rather than a `belongs_to
  User` — it decouples the Work scope from any one host's Identity mount shape. This surface
  therefore renders the id directly (see `Samen.Web.CRM.DashboardLive`'s leaderboard tile) and
  never calls `Samen.Api.PiiResolution`/`Samen.Vault.reveal/3` — there is no vault field on
  this path to resolve. Verified refutably in `crm_reporting_test.exs`, anchored against the
  vault-routed `Person.full_name`, mirroring `crm_dashboard_test.exs`'s own MASKING proof.
  (NOTE: some hosts — `demo` — DO co-mount an Identity scope alongside CRM/Work at the same
  root; `Task.owner_id` still carries no FK/relationship to it either way, by construction —
  the non-PII posture holds on TYPE, not on Identity's absence.)

  ## Rank BEFORE cap (T76 fix round 1, MED-1) — the true top performers always surface

  A prior version discovered AT MOST `Samen.Web.Reads.default_agg_points/0` owners (the
  primitive's OWN discovery step, which orders candidates by owner_id ASCENDING before
  truncating) and only THEN ranked by count — so an org's single most-active member could be
  silently ABSENT from its own leaderboard whenever their uuid happened to sort late. Fixed by
  discovering a much LARGER candidate pool first (`:discovery_limit`, default
  `Samen.Web.Reads.max_agg_points/0` — the primitive's OWN hard ceiling, so this is still a
  single BOUNDED read, never unbounded), ranking THAT full pool by count DESCENDING, and only
  THEN truncating to the DISPLAY count (`:top`, default `Samen.Web.Reads.default_agg_points/0`)
  — cap comes AFTER rank, not before. An org with more distinct CRM-activity owners than
  `:discovery_limit` (a 100+-head-count sales org) can still have the SAME residual — documented
  honestly, not hidden, via `:capped`/`:hidden_owners` below (mirrors `geo_markers!/3`'s
  `capped`/`capped_count` idiom: the exact excess is reported when knowable, `nil` — never a
  fabricated number — when it is not).

  Ties keep the discovery order (owner_id ASC). Excludes unassigned activities (`owner_id ==
  nil`) — a leaderboard ranks MEMBERS, never the unassigned bucket. The primitive's own bounded
  `Other` tail slice (`Samen.Web.Reads.other_key/0`) is UNCONDITIONALLY rejected before ranking
  — it can NEVER appear as a leaderboard row (a fabricated "member" topping the board off the
  arithmetic remainder would be exactly the disclosure-as-content-leak this reject prevents;
  pinned by `crm_reporting_test.exs` + sabotage patch 82).

  Honest empty (all-zero shape) when the org has no owned CRM-anchored activities yet, or when
  no Work scope is mounted for this host (`work_task_resource/1` returns `nil`).

  Returns `%{rows: [%{rank:, owner_id:, count:}], capped:, shown:, hidden_owners:, hidden_count:}`:

    * `:rows` — the ranked, DISPLAY-bounded list (≤ `:top` entries), rank 1..N by count desc.
    * `:shown` — `length(rows)`.
    * `:capped` — `true` when EITHER the discovery pool itself hit `:discovery_limit` OR more
      owners were ranked than `:top` shows.
    * `:hidden_owners` — the EXACT count of additional distinct owners not shown, when knowable
      (discovery was NOT capped — the common case for any realistic org); `nil` (never a
      fabricated number) when discovery itself was capped and the true owner count beyond it is
      unknown.
    * `:hidden_count` — the EXACT count of activities NOT represented in `:rows` (`grand_total -
      shown_total`, both true SQL aggregates) — ALWAYS exact regardless of which cap bound it,
      because it is arithmetic on two real totals, not a row count.

  `opts`:

    * `:top` — the DISPLAY row cap (default `Samen.Web.Reads.default_agg_points/0`).
    * `:discovery_limit` — the ranking-pool discovery cap (default
      `Samen.Web.Reads.max_agg_points/0`; MUST be `>= :top` to rank-before-cap correctly, but
      that invariant is the caller's — this function does not clamp `:top` against it).
  """
  def activity_leaderboard(mount, scope, opts \\ []) do
    top = Keyword.get(opts, :top, Samen.Web.Reads.default_agg_points())
    discovery_limit = Keyword.get(opts, :discovery_limit, Samen.Web.Reads.max_agg_points())

    case work_task_resource(mount) do
      nil ->
        empty_leaderboard()

      task_mod ->
        series =
          task_mod
          |> Ash.Query.new()
          |> Ash.Query.filter(not is_nil(owner_id) and subject_key in ^@crm_subject_keys)
          |> Samen.Web.Reads.aggregate_by!(:owner_id, scope: scope, max_points: discovery_limit)

        other = Samen.Web.Reads.other_key()

        # Rank the FULL discovered pool (never the Other sentinel — MED-2) BEFORE truncating to
        # the display count — this ordering is the whole MED-1 fix: cap comes AFTER rank.
        ranked =
          series.points
          |> Enum.reject(&(&1.key == other))
          |> Enum.sort_by(&(-&1.value))

        shown = Enum.take(ranked, top)
        shown_total = Enum.reduce(shown, 0, &(&1.value + &2))
        grand_total = round_count(Samen.Web.Series.total_value(series))

        # geo_markers!/3's capped_count idiom: an EXACT withheld count when knowable, else nil
        # (never a fabricated number) — discovery capping means the true excess is unknown.
        hidden_owners =
          if series.capped, do: nil, else: max(length(ranked) - top, 0)

        capped? = series.capped or (is_integer(hidden_owners) and hidden_owners > 0)

        rows =
          shown
          |> Enum.with_index(1)
          |> Enum.map(fn {point, rank} -> %{rank: rank, owner_id: point.key, count: round_count(point.value)} end)

        %{
          rows: rows,
          capped: capped?,
          shown: length(rows),
          hidden_owners: hidden_owners,
          hidden_count: max(grand_total - shown_total, 0)
        }
    end
  rescue
    _ -> empty_leaderboard()
  end

  defp empty_leaderboard, do: %{rows: [], capped: false, shown: 0, hidden_owners: 0, hidden_count: 0}

  @doc """
  Pipeline `value` SUMMED per stage as a bounded `%Samen.Web.Series{}` (a DB `sum` per slice,
  org-scoped) — the dashboard's bar breakdown. `stage_cols` are the ordered `{pipeline_id,
  label}` slices. EMPTY series on any error.
  """
  def value_by_stage(mount, scope, stage_cols) do
    Mount.resource(mount, Opportunity)
    |> Samen.Web.Reads.aggregate_by!(:pipeline_id,
      scope: scope,
      measure: {:sum, :value},
      groups: stage_cols
    )
  rescue
    _ -> %Samen.Web.Series{points: [], measure: {:sum, :value}, dimension: :pipeline_id}
  end

  @doc """
  Opportunity COUNT per status as a bounded `%Samen.Web.Series{}` (a DB `count` per slice,
  org-scoped) — the dashboard's pie. Slices are the bounded status enum. EMPTY on any error.
  """
  def opportunities_by_status(mount, scope) do
    Mount.resource(mount, Opportunity)
    |> Samen.Web.Reads.aggregate_by!(:status, scope: scope, groups: @opp_statuses)
  rescue
    _ -> %Samen.Web.Series{points: [], measure: :count, dimension: :status}
  end

  @doc """
  Opportunity COUNT bucketed by `:close_date` month over `[range_start, range_end)` as a bounded
  `%Samen.Web.Series{}` (one DB `count` per month bucket, org-scoped) — the dashboard's line.
  EMPTY on any error.
  """
  def opportunities_over_time(mount, scope, range_start, range_end) do
    Mount.resource(mount, Opportunity)
    |> Samen.Web.Reads.time_series!(:close_date,
      scope: scope,
      range_start: range_start,
      range_end: range_end,
      unit: :month
    )
  rescue
    _ -> %Samen.Web.Series{points: [], measure: :count, dimension: :bucket}
  end

  defp add_months(%Date{year: y, month: m, day: d}, n) do
    total = y * 12 + (m - 1) + n
    ny = div(total, 12)
    nm = rem(total, 12) + 1
    last = Date.days_in_month(%Date{year: ny, month: nm, day: 1})
    Date.new!(ny, nm, min(d, last))
  end

  # -- Work-scope bridge (ADR-041 §6.1) ----------------------------------------

  @doc """
  Derive the host's Work `Task` resource module from a CRM `mount` (the CRM timeline is
  a client of the Work scope, ADR-041 §6.1). The Work scope mounts under the SAME host
  root as the CRM scope; hosts name the domain `<Root>.Work` (driftwood/pawchart/test
  host) or `<Root>.WorkScope` (demo). Try both segments and pick the one that is a live
  Ash resource — CRM-agnostic and host-agnostic, no CRM FK, no hardcoded host module.
  One Postgres + one org/plane per host, so the CRM mount's scope reads/writes Work
  identically. Returns the module, or `nil` if no Work scope is mounted for this host.
  """
  @spec work_task_resource(Mount.t()) :: module() | nil
  def work_task_resource(%Mount{namespace: ns}) do
    root = ns |> Module.split() |> Enum.drop(-1)

    Enum.find_value(["Work", "WorkScope"], fn seg ->
      mod = Module.concat(root ++ [seg, "Task"])
      if work_resource?(mod), do: mod
    end)
  end

  defp work_resource?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :spark_is, 0) and
      Ash.Resource.Info.resource?(mod)
  rescue
    _ -> false
  end

  # -- Mailbox-scope bridge (spec §I1 CRM two-way email sync, T74) --------------
  #
  # The SAME host-root derivation the Work bridge uses: no CRM FK, no hardcoded
  # host module. A host that has NOT mounted `Samen.Scopes.Mailbox` gets `nil` here
  # and an EMPTY timeline/settings surface — the honest absence, never fake mail.

  @doc """
  Derive the host's `Mailbox.MailMessage` module from a CRM `mount`, or `nil` when
  the Mailbox scope is not mounted for this host.
  """
  @spec mailbox_message_resource(Mount.t()) :: module() | nil
  def mailbox_message_resource(mount), do: mailbox_resource(mount, "MailMessage")

  @doc """
  Derive the host's `Mailbox.Connection` module from a CRM `mount`, or `nil` when
  the Mailbox scope is not mounted for this host.
  """
  @spec mailbox_connection_resource(Mount.t()) :: module() | nil
  def mailbox_connection_resource(mount), do: mailbox_resource(mount, "Connection")

  defp mailbox_resource(%Mount{namespace: ns}, name) do
    root = ns |> Module.split() |> Enum.drop(-1)

    Enum.find_value(["Mailbox", "MailboxScope"], fn seg ->
      mod = Module.concat(root ++ [seg, name])
      if work_resource?(mod), do: mod
    end)
  end

  defp mailbox_resource(_mount, _name), do: nil

  @doc """
  Read a person's synced mailbox messages, newest-first — BOTH directions (the
  two-way sync's inbound AND outbound legs). 🔒 `subject`/`body`/
  `counterparty_address` are resolved through `Samen.Api.PiiResolution` on the
  actor's plane, exactly like every other PII read on this surface: tenant clear,
  operator-without-grant `••••`. Returns `[]` — the honest empty list — when no
  Mailbox scope is mounted.
  """
  def mail_for_person(mount, scope, person_id) do
    pid = to_string(person_id)

    read_mail(mount, scope, fn query ->
      Ash.Query.filter(query, subject_key == "crm.person" and subject_id == ^pid)
    end)
  end

  @doc """
  Read a company's synced mailbox messages, newest-first. A message anchored to a
  PERSON at that company appears here too (the secondary `company_id` anchor) —
  zero timeline loss, the same OR-shape `activities_for_company/3` uses.
  """
  def mail_for_company(mount, scope, company_id) do
    cid = to_string(company_id)

    read_mail(mount, scope, fn query ->
      Ash.Query.filter(
        query,
        (subject_key == "crm.company" and subject_id == ^cid) or company_id == ^cid
      )
    end)
  end

  defp read_mail(mount, scope, build_query) do
    case mailbox_message_resource(mount) do
      nil ->
        []

      resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected(@mail_fields)
        |> build_query.()
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)
        |> resolve_mail_pii(mount, resource, scope)
    end
  rescue
    _ -> []
  end

  # The SAME PiiResolution chokepoint `resolve_pii/4` uses — kept separate only
  # because the Mailbox resource is derived from the host root, not from the CRM
  # mount's own namespace map.
  defp resolve_mail_pii(records, mount, resource, scope) do
    Samen.Api.PiiResolution.resolve(records, resource, actor_of(scope), repo: mount.repo)
  rescue
    _ -> records
  end

  @doc """
  Read this org's mailbox connections (newest first), bounded. `[]` when the
  Mailbox scope is not mounted — the honest absence, which the CRM mailbox settings
  surface renders as "not connected", never as "no mail yet".
  """
  def mailbox_connections(mount, scope) do
    case mailbox_connection_resource(mount) do
      nil ->
        []

      resource ->
        resource
        |> Ash.Query.new()
        |> Ash.Query.ensure_selected(@connection_fields)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)
        |> resolve_mail_pii(mount, resource, scope)
    end
  rescue
    _ -> []
  end

  # Resolve the CRM subject anchor (precedence opportunity ▸ person ▸ company, ADR-041
  # §5.1) THROUGH the org-scoped ObjectRef resolve so a cross-org id is inert
  # (`{:error, :not_found}`), never anchored. No subject id → an anchorless task.
  defp resolve_crm_subject(mount, scope, attrs) do
    case crm_anchor(attrs) do
      nil ->
        {:ok, {nil, nil}}

      {key, id} ->
        ref = %ObjectRef{key: key, id: to_string(id), raw: ObjectRef.to_string(key, to_string(id))}

        case ObjectRef.resolve(mount, scope, ref) do
          {:ok, _card} -> {:ok, {key, to_string(id)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The primary CRM anchor from the composer attrs, by ADR-041 §5.1 precedence.
  defp crm_anchor(attrs) do
    cond do
      (id = fetch_attr(attrs, :opportunity_id)) && id != "" -> {"crm.opportunity", id}
      (id = fetch_attr(attrs, :person_id)) && id != "" -> {"crm.person", id}
      (id = fetch_attr(attrs, :company_id)) && id != "" -> {"crm.company", id}
      true -> nil
    end
  end

  # Map the composer's activity attrs onto Task attrs (ADR-041 §5.1): type→kind,
  # subject→title, verbatim body/status/due_at/completed_at/org_id. Accepts either the
  # legacy activity names or the Task names; drops the CRM FK keys (they become the
  # anchor + crm_refs). Atom-keyed (the Reads API / tests pass an atom map).
  defp activity_to_task_attrs(attrs) do
    %{
      kind: fetch_attr(attrs, :kind) || fetch_attr(attrs, :type),
      title: fetch_attr(attrs, :title) || fetch_attr(attrs, :subject),
      body: fetch_attr(attrs, :body),
      status: fetch_attr(attrs, :status),
      due_at: fetch_attr(attrs, :due_at),
      completed_at: fetch_attr(attrs, :completed_at),
      org_id: fetch_attr(attrs, :org_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp fetch_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  # -- private -----------------------------------------------------------------

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

  defp count_resource(resource, scope) do
    Ash.count!(resource, scope: scope)
  rescue
    _ -> 0
  end

  defp sum_resource(query, field, scope) do
    Ash.sum!(query, field, scope: scope) || 0
  rescue
    _ -> 0
  end
end
