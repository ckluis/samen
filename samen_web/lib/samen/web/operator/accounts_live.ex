defmodule Samen.Web.Operator.AccountsLive do
  @moduledoc """
  Framework OPERATOR / Accounts page (ADR-010 §4a) — the operator CRM where each account IS a
  tenant org. Reads `Identity.Org` rows (operator namespace, operator-org-scoped) as ACCOUNTS,
  each joined to its admin `Identity.User`s (the tenant-ADMINS — PII CLEAR, the SaaS's own
  signup contacts), its subscription-to-the-SaaS (plan/MRR/status), a seat proxy, and its open
  desk-ticket count.

  ## The identity line, clear side (ADR-010 §5)

  This page reads the OPERATOR ORG's OWN book of business on the TENANT plane
  (`Samen.Web.Operator.scope/1`). The tenant-admin's name/email render IN THE CLEAR because the
  `plane: :tenant` resolver clears own-org PII — the SaaS owns this data. The tenant's DOWNSTREAM
  end-customers are NOT read here; "Open account" LINKS to the ADR-009 impersonation surface
  (`plane: :operator`, masked) via the `tenant_org_id` back-reference. This LiveView NEVER calls
  the vault, NEVER unwraps a `%Masked{}`, and has NO plaintext branch.

  ## A3 retrofit — ListLive + the ONE sanctioned write

  The list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.accounts_page/3` buys sort/filter/keyset-pagination/empty-state as kit defaults
  (no unbounded `read!`, no list `handle_event/3` of its own). The write side (AC-G1-1/2):
  "New account" opens a `modal/1` hosting an `AshPhoenix.Form`-backed `simple_form/1` over
  the Identity `Org` CREATE — the only account write the domain defines for this surface
  (the anchor's bootstrap create; `name` is required so the inline-error path is real; NO
  PII fields — `Org` carries name/plan/slug only, ADR-010 §8.3). There is deliberately NO
  account delete: the Org anchor's destroy is `OrgIsSelf`-gated and the domain defines no
  operator offboarding action. Write affordances are offered on the operator workspace's
  tenant plane only (`Samen.Web.Operator.Live.writable?/1`); enforcement stays in the
  kernel (the Org policy + `Samen.Pii.WriteGuard` on any PII-bearing resource).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  use Samen.Web.ListLive,
    resource: Org,
    reads: &Samen.Web.Operator.Reads.accounts_page/3,
    sortable: [:name, :plan],
    filter_fields: [:name],
    default_sort: {:name, :asc}

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    case operator_org_id do
      nil ->
        socket
        |> assign(no_org: true, operator_org_id: nil, metrics: nil)
        |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
        |> assign(show_new: false, new_form: nil)
        |> assign(scope_masking?: false, name_scope: :none)

      org_id ->
        scope = Operator.scope(mount)
        otp_app = Operator.otp_app(mount)
        operator_id = acting_operator_id(socket, mount)

        socket
        |> assign(
          no_org: false,
          operator_org_id: org_id,
          metrics: Reads.account_metrics(mount, scope, org_id),
          # ADR-044 Amendment-1 account-level NAME scoping (§16.2/§16.4a, T159). The SAME
          # keyless `scope_of/2` seam the R-B impersonation drill-in gate uses
          # (`Samen.Web.Operator.Impersonation`): an operator sees an account's NAME only
          # when the account org is in their `scope_of/2`. `scope_masking?` engages ONLY
          # when the product wires a `:fleet_resolution` seam — a product with none gets
          # today's all-clear behaviour + the no-lockout property (§16.4a). A resolver
          # bug fails CLOSED to `:none` (mask-by-omission), never toward exposure.
          scope_masking?: Samen.Fleet.Resolution.configured?(otp_app),
          name_scope: Samen.Fleet.Resolution.scope_of(otp_app, operator_id)
        )
        |> assign_new(:show_new, fn -> false end)
        |> assign(new_form: new_account_form(mount, scope))
        |> init_list(mount, scope)
    end
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_account", _params, socket) do
    mount = socket.assigns.samen_mount
    {:noreply, assign(socket, show_new: true, new_form: new_account_form(mount, Operator.scope(mount)))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # The account create. `org_id` (the operator org — the account row lives in the
  # operator's book) is the server-side fact, never client input. `Org` carries NO PII;
  # the kernel's always-authorized anchor create is the domain action — this LiveView
  # adds no policy of its own.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _org} ->
        {:noreply, socket |> assign(show_new: false) |> load()}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  defp new_account_form(mount, scope) do
    Mount.resource(mount, Org)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.operator_org_id)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-accounts">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:accounts} />
        </:sidebar>

        <.topbar title="Accounts" crumbs={["Operator plane", "Accounts"]}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_account" id="new-account">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New account
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved. Seed the operator org or configure
              <code>operator_org_id</code>.
            </div>
          </div>
        <% else %>
          <div class="metrics">
            <.metric label="Accounts" value={@metrics && @metrics.accounts || 0} sub="tenant orgs">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Healthy" value={@metrics && @metrics.active || 0} sub="healthy band · dunning-coherent">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="At risk" value={@metrics && @metrics.at_risk || 0} sub="at-risk + critical bands">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Platform MRR" value={dollars((@metrics && @metrics.mrr_cents) || 0)} sub="across accounts">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="accounts">
              <div class="gtitle">
                <h3>Accounts</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· each account IS a tenant org · primary contact (tenant-admin) in the clear</span>
              </div>
              <.list_view
                id="accounts-list"
                page={@page}
                state={@list_state}
                row_class="account-row"
                filter_placeholder="Filter accounts…"
                empty_text="No accounts yet."
                empty_icon="▤"
                empty_body="Accounts are the tenant orgs on your platform — create the first to open your book of business."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_account" id="empty-new-account">New account</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Account" sort={@list_state.sort} width="24%" />
                  <th scope="col" style="width:22%">Primary contact</th>
                  <th scope="col" style="width:20%">Email</th>
                  <.sort_header field={:plan} label="Plan" sort={@list_state.sort} width="10%" />
                  <th scope="col" style="width:8%">Health</th>
                  <th scope="col" style="width:8%">Seats</th>
                  <th scope="col" style="width:8%">MRR</th>
                </:head>
                <:row :let={a}>
                  <%= if name_masked?(@scope_masking?, @name_scope, a.tenant_org_id) do %>
                    <%!--
                      Mask by omission (ADR-044 §16.4a, T159): the row STILL EXISTS (its
                      non-identifying aggregates — plan, health band/score, seats, MRR —
                      render), but the account's IDENTITY does not: NO name, NO tenant-admin
                      contact/email, NO `tenant_org_id`/`id` handle in ANY href/attribute,
                      NO drill/open/impersonate deep link. Never a plaintext name, never a
                      leaking token — the fleet tier-2 mask-by-omission rule, on this surface.
                    --%>
                    <td class="a-name a-name-masked">
                      <div style="display:flex;align-items:center;gap:8px">
                        <div class="av" style="width:28px;height:28px;border-radius:6px;background:#ECECF2;color:#9aa0b5;font-size:12px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                          •
                        </div>
                        <span class="masked-affordance" style="color:var(--muted)">not in your scope</span>
                      </div>
                    </td>
                    <td class="a-contact" style="color:var(--muted)">—</td>
                    <td class="a-email" style="font-size:12px;color:var(--muted)">—</td>
                    <td class="a-plan" style="color:var(--muted)">{a.plan || "—"}</td>
                    <td class="a-health">
                      <.pill variant={health_variant(a.__health__.band)}>
                        {health_label(a.__health__.band)} · {a.__health__.score}
                      </.pill>
                    </td>
                    <td class="a-seats" style="color:var(--muted)">{a.__seats__}</td>
                    <td class="a-mrr" style="color:var(--muted)">{dollars(a.__mrr_cents__)}</td>
                  <% else %>
                    <td class="a-name">
                      <div style="display:flex;align-items:center;gap:8px">
                        <div class="av" style="width:28px;height:28px;border-radius:6px;background:#DDE2F5;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                          {account_initials(a.name)}
                        </div>
                        <div>
                          <span style="font-weight:500;color:#3a3b45">{a.name}</span>
                          <div :if={a.tenant_org_id} style="display:flex;gap:10px;font-size:11px">
                            <%!-- S7: act-as is a session WRITE — a zero-JS CSRF-protected
                                 POST form, never a forgeable GET link. --%>
                            <form
                              method="post"
                              action={open_account_href(@samen_mount, a.tenant_org_id)}
                              style="margin:0;display:inline"
                            >
                              <input
                                type="hidden"
                                name="_csrf_token"
                                value={Plug.CSRFProtection.get_csrf_token_for(open_account_href(@samen_mount, a.tenant_org_id))}
                              />
                              <button
                                type="submit"
                                class="open-account"
                                style="color:#3B4CCA;background:none;border:0;padding:0;font:inherit;cursor:pointer"
                                title="Act as this tenant on the TENANT plane (clear) — fill out / QA the demo"
                              >
                                Open account →
                              </button>
                            </form>
                            <a
                              class="impersonate-account"
                              href={impersonate_href(@samen_mount, a.tenant_org_id)}
                              style="color:var(--muted)"
                              title="Impersonate on the OPERATOR plane (masked) — the support drill-in"
                            >
                              Impersonate (masked) →
                            </a>
                          </div>
                        </div>
                      </div>
                    </td>
                    <td class="a-contact" style="font-weight:500;color:#3a3b45">
                      {primary_contact_name(a.__admins__)}
                    </td>
                    <td class="a-email" style="font-size:12px;color:var(--muted)">
                      {primary_contact_email(a.__admins__)}
                    </td>
                    <td class="a-plan" style="color:var(--muted)">{a.plan || "—"}</td>
                    <td class="a-health">
                      <a
                        class="account-drill"
                        href={"/operator/accounts/#{a.id}"}
                        title="Health drill-down — why this score (ADR-019)"
                        style="text-decoration:none"
                      >
                        <.pill variant={health_variant(a.__health__.band)}>
                          {health_label(a.__health__.band)} · {a.__health__.score}
                        </.pill>
                      </a>
                    </td>
                    <td class="a-seats" style="color:var(--muted)">{a.__seats__}</td>
                    <td class="a-mrr" style="color:var(--muted)">{dollars(a.__mrr_cents__)}</td>
                  <% end %>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-account-modal" title="New account" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-account-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Account name" />
              <.form_field field={f[:plan]} label="Plan" />
              <:actions>
                <.button variant="primary" type="submit">Save account</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- entry helpers (ADR-013 §5.2 — two clean grades of drill-in) --------------

  # (1) Act-as / CLEAR — set the session current org via the framework SessionController and
  # land in the tenant's workspace on the TENANT plane. The tenant landing path is a mount
  # label (`:tenant_landing`, default `/broker`) so a host lands you on its own home page.
  # Since S7 this is a POST form ACTION (the switch writes the session; CSRF-protected),
  # not a GET href — the query-string `return_to` merges into the POST params.
  defp open_account_href(mount, tenant_org_id) do
    landing = Samen.Web.Mount.label(mount, :tenant_landing, "/broker")
    "/session/org/#{tenant_org_id}?return_to=#{URI.encode_www_form(landing)}"
  end

  # (2) Impersonate / MASKED — the EXISTING operator-plane impersonation drill-in (ADR-009/010),
  # a host-supplied path (`:impersonate_path` label, default `/operator/impersonate`) carrying
  # the tenant org via `?org=`. The plane (not the session) is what masks.
  defp impersonate_href(mount, tenant_org_id) do
    path = Samen.Web.Mount.label(mount, :impersonate_path, "/operator/impersonate")
    "#{path}?org=#{tenant_org_id}"
  end

  # -- ADR-044 Amendment-1 account-level name scoping (§16.4a, T159) ------------

  @doc """
  The account-level NAME-scope predicate — `true` ⇒ this account's NAME (and its
  identifying contact + linkage handles) must be masked-by-omission for the acting
  operator. KEYLESS `org_id` membership against the operator's `scope_of/2` value
  (`Samen.Fleet.Resolution.in_scope?/2`) — the SAME seam the R-B impersonation
  drill-in gate tests (`Samen.Web.Operator.Impersonation`), on the account's
  `tenant_org_id` (the impersonation back-reference `scope_of/2` returns org_ids for).

  Inert (`false` — every name clear, today's behaviour) when the product wires no
  `:fleet_resolution` seam (`scope_masking?` false): the no-lockout property. `scope_of/2`
  itself fails CLOSED to `:none` on any error, so a wired-but-erroring seam masks
  (mask-by-omission), never exposes. This is NAME-scoping layered ON TOP of the T146
  operator-role gate — it never substitutes for it.
  """
  @spec name_masked?(boolean(), Samen.Fleet.Resolution.scope(), String.t() | nil) :: boolean()
  def name_masked?(scope_masking?, name_scope, tenant_org_id) do
    scope_masking? and not Samen.Fleet.Resolution.in_scope?(name_scope, tenant_org_id)
  end

  # The acting operator id used to read `scope_of/2`: the authenticated principal
  # (`:samen_operator_id`, assigned by `Samen.Web.Operator.Authz`'s `:require_operator`
  # on_mount from the signed session principal) when present, else the operator seat's
  # well-known org id — the SAME fallback ladder the drill-in gate uses
  # (`Samen.Web.Operator.Impersonation.resolve_operator_id/3`), so the scope answer is
  # consistent between the accounts list and a drill-in opened from it.
  defp acting_operator_id(socket, mount) do
    case socket.assigns[:samen_operator_id] do
      id when is_binary(id) -> id
      _ -> Operator.org_id(mount)
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp primary_contact_name([admin | _]), do: render_name(admin.full_name)
  defp primary_contact_name(_), do: "—"

  defp primary_contact_email([admin | _]), do: render_email(admin.emails)
  defp primary_contact_email(_), do: "—"

  defp account_initials(nil), do: "?"

  defp account_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  # The ADR-019 composite bands (the old status-only pill is gone — it disagreed
  # with dunning; `__health__` is now the `HealthScore` breakdown and the pill
  # links to the drill-down that explains it).
  defp health_variant(:healthy), do: "ok"
  defp health_variant(:watch), do: "info"
  defp health_variant(:at_risk), do: "warn"
  defp health_variant(:critical), do: "bad"
  defp health_variant(_), do: "mut"

  defp health_label(:healthy), do: "healthy"
  defp health_label(:watch), do: "watch"
  defp health_label(:at_risk), do: "at risk"
  defp health_label(:critical), do: "critical"
  defp health_label(_), do: "unknown"
end
