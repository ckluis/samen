defmodule Samen.Web.Billing.SettingsLive do
  @moduledoc """
  Framework Billing / Settings page (B10, T26) — host-agnostic (ADR-009), the LAST
  billing consumer before T106's production-mirror unification.

  Renders on the ONE predicate ADR-038 §3.5 names: `Samen.Billing.Provider.configured?/1`
  for the host's `:billing_provider` config, "no separate flag to drift":

    * **configured** — a plan picker (`Samen.Billing.Checkout.create_session/2`, T20,
      redirects to the vendor-hosted checkout), a "Manage payment method" affordance
      (`Samen.Billing.PaymentMethod.create_portal_session/2`, T23, redirects to the
      vendor-hosted portal — NEVER a card form), and recent invoice history
      (`Reads.invoices_page/3`, T22 — the same masked read every other billing page
      uses, hosted invoice/receipt links only).
    * **unconfigured** — the HONEST "bring your billing" empty state (`not_configured_copy/0`):
      ZERO fake affordances. No fabricated plan, no dead checkout/payment-method button,
      no card form — the INV-4 spirit made visible on a page (ADR-038 §3.5 B10).

  This module composes the shipped T20/T22/T23 surfaces; it does not reimplement any of
  their logic (no new checkout/invoice/payment-method business rules land here).

  ## MASKING INVARIANT

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Samen.Masked{}`. The recent-invoice
  read rides `Reads.invoices_page/3` (T22's own PiiResolution-backed customer join)
  UNCHANGED; the optional billing-contact sync forwarded to the payment-method portal
  session only ever forwards an ALREADY-PLAINTEXT (`is_binary/1`) value — a `%Masked{}`
  customer (impossible here anyway, since the checkout/portal affordances are
  `writable?/1`-gated to the tenant plane) is silently dropped, never stringified.

  ## Vendor cross-references

  `provider_customer_ref` / `provider_price_ref` are referenced under their CURRENT names per
  the billing-blueprint collision-group rule (T18's documented, ratcheted carve-out;
  T106 owns the vendor-neutral rename). `samen_web` is not INV-4-scoped the way
  `samen_core` is (`billing_vendor_free_test.exs` only greps `samen_core/lib`) — these
  are plain Ash attribute reads on the existing Billing blueprint, the same shape
  `Reads` already hardcodes for every other Plan/Price/Customer field.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Billing.Checkout
  alias Samen.Billing.PaymentMethod
  alias Samen.Web.CurrentOrg
  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Reads.Guard
  alias Samen.Web.Page

  alias Samen.Web.Billing.Reads
  alias Samen.Web.Settings.Reads, as: SettingsReads

  @doc """
  The EXACT honest "bring your billing" empty-state copy (done-criterion 2). Rendered
  ONLY when `Samen.Billing.Provider.configured?/1` is `false` for the host's
  `:billing_provider` config — the SAME predicate that drives every callback's
  `{:error, :not_configured}` refusal (ADR-038 §3.2/§3.5), so this page can never drift
  from what the rest of the billing surface honestly reports.
  """
  @spec not_configured_copy() :: String.t()
  def not_configured_copy,
    do:
      "No billing provider is configured for this workspace — plans, payment methods, " <>
        "and invoice history are unavailable until one is wired. Set " <>
        "config :samen_core, :billing_provider (see docs/adr/ADR-038-adapter-architecture.md)."

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    # PP-5: the acting user (the SAME current-user seam the api-key settings surface uses)
    # — needed to resolve the REAL per-org membership role for the admin-gated billing writes.
    user_id = SettingsReads.current_user_id(mount, params, session)
    {:ok, load(assign(socket, org_id: org_id, user_id: user_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    user_id = Samen.Web.Settings.Reads.reresolve_user(socket, params)

    {:noreply,
     load(
       assign(socket, org_id: org_id, user_id: user_id, return_to: return_path(uri), current_uri: uri),
       org_id
     )}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> ensure_current_uri()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, configured: false)
    |> assign(plans_with_prices: [], customer: nil, recent_invoices: %Page{}, section_errors: [])
    |> assign(checkout_error: nil, portal_error: nil)
    |> assign(billing_actor: nil, billing_admin?: false, billing_actor_failed?: false)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    configured = provider_configured?()
    # PP-5: the REAL per-org billing actor (role read from the caller's Membership, NOT the
    # synthetic `:member` Mount.scope default). This is the actor billing WRITES run under;
    # the admin gate is enforced BOTH here (affordance) and in the core BY CONSTRUCTION.
    {actor, actor_failed?} =
      case billing_actor(mount, org_id, socket.assigns[:user_id]) do
        {:ok, actor} -> {actor, false}
        {:error, :not_found} -> {nil, false}
        # The role lookup FAILED (an outage): still fail CLOSED (no actor, no admin affordances, the
        # write refuses), but the screen says it could not check — it must not tell an admin that
        # only an admin can do this.
        {:error, :unavailable} -> {nil, true}
      end

    socket
    |> ensure_return_to()
    |> ensure_current_uri()
    |> assign(no_org: false, org_id: org_id, configured: configured)
    |> assign(billing_actor: actor, billing_admin?: admin_actor?(actor), billing_actor_failed?: actor_failed?)
    |> assign_new(:checkout_error, fn -> nil end)
    |> assign_new(:portal_error, fn -> nil end)
    |> load_billing(mount, scope, configured)
  end

  defp load_billing(socket, _mount, _scope, false) do
    assign(socket, plans_with_prices: [], customer: nil, recent_invoices: %Page{}, section_errors: [])
  end

  defp load_billing(socket, mount, scope, true) do
    # Each section fails on its own (`section_errors`): a failed plans read is not "No plans yet",
    # a failed customer read is not "Available after your first subscription", and a failed
    # invoices read is not "No invoices yet".
    plans = Reads.plans_with_prices_result(mount, scope)
    customers = Reads.customers_result(mount, scope)
    invoices = Reads.invoices_page(mount, scope, %ListState{page_size: 5, sort: {:due_date, :desc}})

    assign(socket,
      plans_with_prices: Guard.value(plans, []),
      customer: customers |> Guard.value([]) |> List.first(),
      recent_invoices: invoices,
      section_errors:
        for({key, failed?} <- [plans: Guard.unavailable?(plans), customer: Guard.unavailable?(customers), invoices: Guard.unavailable?(invoices)], failed?, do: key)
    )
  end

  # -- events --------------------------------------------------------------------

  # The kit error state's "Try again" (a failed plans / customer / invoices read).
  @impl true
  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket, socket.assigns.org_id)}

  def handle_event("checkout", %{"plan_id" => plan_id}, socket) do
    cond do
      # PP-5: subscribing is a billing WRITE — admin+ only, by ROLE (not plane). The UI
      # affordance is already role-gated; this refuses a member/viewer who forces the event.
      not socket.assigns.billing_admin? ->
        {:noreply, assign(socket, checkout_error: refusal_copy(socket))}

      true ->
        case find_plan_price_ref(socket, plan_id) do
          nil ->
            {:noreply, assign(socket, checkout_error: "This plan has no price configured yet.")}

          price_ref ->
            attrs = %{
              org_id: socket.assigns.org_id,
              plan_id: plan_id,
              price_ref: price_ref,
              success_url: settings_url(socket, %{"checkout" => "success"}),
              cancel_url: settings_url(socket, %{"checkout" => "cancel"}),
              customer_ref: customer_ref(socket)
            }

            with {:ok, provider, provider_config} <- billing_provider(),
                 {:ok, %{url: url}} <-
                   Checkout.create_session(attrs,
                     provider: provider,
                     provider_config: provider_config,
                     actor: socket.assigns.billing_actor
                   ) do
              {:noreply, redirect(socket, external: url)}
            else
              _ -> {:noreply, assign(socket, checkout_error: "Could not start checkout. Please try again.")}
            end
        end
    end
  end

  def handle_event("manage_payment_method", _params, socket) do
    cond do
      # PP-5: opening the portal changes the card / cancels the subscription — admin+ only.
      not socket.assigns.billing_admin? ->
        {:noreply, assign(socket, portal_error: refusal_copy(socket))}

      true ->
        case socket.assigns.customer do
          %{provider_customer_ref: ref} when is_binary(ref) and ref != "" ->
            attrs =
              %{org_id: socket.assigns.org_id, customer_ref: ref, return_url: settings_url(socket, %{})}
              |> maybe_put_billing_contact(socket.assigns.customer)

            with {:ok, provider, provider_config} <- billing_provider(),
                 {:ok, %{url: url}} <-
                   PaymentMethod.create_portal_session(attrs,
                     provider: provider,
                     provider_config: provider_config,
                     actor: socket.assigns.billing_actor
                   ) do
              {:noreply, redirect(socket, external: url)}
            else
              _ -> {:noreply, assign(socket, portal_error: "Could not open the billing portal. Please try again.")}
            end

          _ ->
            {:noreply, assign(socket, portal_error: "Subscribe to a plan before managing a payment method.")}
        end
    end
  end

  # -- helpers ---------------------------------------------------------------

  @admin_only_copy "Only an admin can manage billing for this workspace."

  # PP-5 (Batch 2 TENANT-ROLE): the REAL per-org billing actor. Resolves the caller's
  # `Membership` role in this org (`Reads.current_membership_result`, the tagged sibling of the
  # seam the api-key MINT handler uses to gate on the real role) and builds a tenant-plane actor
  # carrying that role — NEVER the synthetic `:member` of `Mount.scope/2`.
  #
  #   * `{:ok, actor}` — the real membership role;
  #   * `{:error, :not_found}` — no user in context or no membership in this org: no authority;
  #   * `{:error, :unavailable}` — the LOOKUP FAILED (an outage). Equally no authority — billing
  #     writes FAIL CLOSED either way (affordance hidden, handler refuses, and the core function
  #     refuses by construction) — but the screen shows an error state, not "only an admin can".
  #
  # The billing mount's own namespace is a Billing scope, which does not materialize
  # `User`/`Membership`; the host wires the identity scope onto the mount via the
  # `:identity_namespace` label (the same sibling-mount seam Marketing uses for
  # `:crm_namespace`). Absent the label the billing mount itself is used (a host whose
  # billing namespace already carries identity resources still resolves).
  defp billing_actor(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    identity = identity_mount(mount)
    scope = Mount.scope(identity, org_id)

    case SettingsReads.current_membership_result(identity, scope, user_id, org_id) do
      {:ok, membership} ->
        {:ok, %{id: user_id, org_id: org_id, role: membership.role, kind: :tenant, plane: :tenant}}

      {:error, :unavailable} = unavailable ->
        unavailable

      {:error, _not_found_or_forbidden} ->
        {:error, :not_found}
    end
  rescue
    e ->
      Guard.report(:billing_actor, org_id, e)
      {:error, :unavailable}
  end

  defp billing_actor(_mount, _org_id, _user_id), do: {:error, :not_found}

  # Derive an Identity-kind mount from the billing mount + the host's `:identity_namespace`
  # label (same repo + plane), so `User`/`Membership` resolve off the identity scope. No
  # label → the billing mount itself (unchanged), which fail-closes for a Billing-only
  # namespace since it materializes no `Membership`.
  defp identity_mount(mount) do
    case Mount.label(mount, :identity_namespace, nil) do
      ns when is_atom(ns) and not is_nil(ns) ->
        Mount.new(:settings, ns, mount.repo, plane: mount.plane, domain: ns, labels: mount.labels)

      _ ->
        mount
    end
  end

  defp admin_actor?(%{role: role}), do: Samen.Scope.Role.at_least?(role, :admin)
  defp admin_actor?(_), do: false

  defp admin_only_copy, do: @admin_only_copy

  defp refusal_copy(socket) do
    if socket.assigns[:billing_actor_failed?],
      do: "We couldn't check your role right now, so nothing was changed. Try again.",
      else: admin_only_copy()
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  defp ensure_current_uri(socket) do
    if Map.has_key?(socket.assigns, :current_uri), do: socket, else: assign(socket, current_uri: nil)
  end

  # Provider resolution — the SAME `Application.get_env(:samen_core, :billing_provider)`
  # shape `Samen.Billing.WebhookDispatch`/`Samen.Billing.UsageReportWorker` use (ADR-038
  # §3.5), so an unwired host is a safe, honest `:not_configured` — never a crash.
  defp billing_provider do
    case Application.get_env(:samen_core, :billing_provider) do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, module, config}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, %{}}
      _ -> :not_configured
    end
  end

  defp provider_configured? do
    case billing_provider() do
      {:ok, module, config} -> module.configured?(config)
      :not_configured -> false
    end
  end

  defp find_plan_price_ref(socket, plan_id) do
    case Enum.find(socket.assigns.plans_with_prices, fn %{plan: plan} -> plan.id == plan_id end) do
      %{prices: prices} -> prices |> pick_price() |> price_ref()
      _ -> nil
    end
  end

  defp price_ref(%{provider_price_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp price_ref(_), do: nil

  defp customer_ref(%{assigns: %{customer: %{provider_customer_ref: ref}}}) when is_binary(ref) and ref != "", do: ref
  defp customer_ref(_), do: nil

  defp maybe_put_billing_contact(attrs, customer) do
    attrs
    |> maybe_put(:billing_name, plain(Map.get(customer, :billing_name)))
    |> maybe_put(:billing_email, plain(Map.get(customer, :billing_email)))
  end

  # NEVER unwraps a %Samen.Masked{} — a masked value simply fails the is_binary/1 guard
  # and is dropped, exactly the MASKING INVARIANT this module documents.
  defp plain(v) when is_binary(v), do: v
  defp plain(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Builds an absolute (when `@current_uri` is known) or path-relative return URL back to
  # THIS settings page, carrying `org` + whatever `extra` query params the caller adds.
  # `Checkout.create_session/2` / `PaymentMethod.create_portal_session/2` additionally
  # force-org-scope every redirect URL themselves (their own guard) — this is only the
  # base URL construction, not a second org-scoping mechanism.
  defp settings_url(socket, extra) do
    path = socket.assigns[:return_to] || "/billing/settings"
    query = URI.encode_query(Map.merge(%{"org" => socket.assigns.org_id}, extra))

    case socket.assigns[:current_uri] do
      uri when is_binary(uri) ->
        parsed = URI.parse(uri)
        %{parsed | path: path, query: query} |> URI.to_string()

      _ ->
        "#{path}?#{query}"
    end
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Billing", leaf]

  defp payment_method_available?(%{provider_customer_ref: ref}), do: is_binary(ref) and ref != ""
  defp payment_method_available?(_), do: false

  # The plan-card display price + the checkout price_ref both pick the same one price:
  # the first ACTIVE price, falling back to the first price at all (a plan with only
  # inactive prices still shows/charges SOMETHING rather than silently picking none).
  defp pick_price(prices), do: Enum.find(prices, & &1.active) || List.first(prices)

  # Fail-honest display (the `PlansLive.primary_price/1` precedent): a plan with NO
  # price yet renders "—", never a fabricated "$0.00" — a real absence is not a real zero.
  defp price_display(prices) do
    case pick_price(prices) do
      nil -> "—"
      price -> dollars(price.unit_amount)
    end
  end

  defp price_interval_display(prices, plan_interval) do
    case pick_price(prices) do
      nil -> interval_label(plan_interval)
      price -> interval_label(price.interval)
    end
  end

  defp interval_label(:monthly), do: "monthly"
  defp interval_label(:annual), do: "annual"
  defp interval_label(:weekly), do: "weekly"
  defp interval_label(:daily), do: "daily"
  defp interval_label(:one_time), do: "one-time"
  defp interval_label(other), do: to_string(other)

  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  defp dollars(_), do: "$0.00"

  defp tax_display(nil), do: "—"
  defp tax_display(cents) when is_integer(cents), do: dollars(cents)
  defp tax_display(_), do: "—"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  defp format_date(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp render_billing_name(nil), do: "—"
  defp render_billing_name(%{billing_name: %Samen.Masked{} = m}), do: m
  defp render_billing_name(%{billing_name: name}) when is_binary(name), do: name
  defp render_billing_name(_), do: "—"

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-settings">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_settings} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Settings" crumbs={crumbs(@samen_mount, @org_id, "Settings")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing settings org: {@org_id}</span>

          <%= if @configured do %>
            <div class="wrap" id="billing-settings-configured">
              <div :if={@checkout_error} class="card form-error" id="checkout-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:14px">
                {@checkout_error}
              </div>
              <div :if={@portal_error} class="card form-error" id="portal-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:14px">
                {@portal_error}
              </div>
              <.error_state :if={@billing_actor_failed?} class="billing-role-error" body="We couldn't check your role right now. Billing actions are hidden until we can." retry_event="retry_load" />

              <div id="plan-picker">
                <div class="gtitle">
                  <h3>Plans</h3>
                  <span class="lane">· hosted checkout — samen never handles card data</span>
                </div>

                <.error_state :if={:plans in @section_errors} class="plan-picker-error" body={Guard.message()} retry_event="retry_load" />

                <.empty_state
                  :if={@plans_with_prices == [] and :plans not in @section_errors}
                  class="plan-picker-empty"
                  icon="◫"
                  title="No plans yet"
                  body="Create a plan on the Plans page before customers can subscribe."
                />

                <div :if={@plans_with_prices != []} style="display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-bottom:20px">
                  <div :for={%{plan: plan, prices: prices} <- @plans_with_prices} class="card plan-picker-card" id={"plan-picker-#{plan.id}"} style="padding:16px">
                    <div style="font-weight:600;color:#3a3b45">{plan.label || plan.name}</div>
                    <div style="font-size:12px;color:var(--muted);margin:4px 0 10px">
                      {plan.description || plan.name}
                    </div>
                    <div style="font-weight:600;font-size:18px;color:#3a3b45">
                      {price_display(prices)}
                      <span :if={pick_price(prices)} style="font-size:11px;font-weight:400;color:var(--muted)">
                        / {price_interval_display(prices, plan.interval)}
                      </span>
                    </div>
                    <.button
                      :if={writable?(@samen_mount) and @billing_admin?}
                      variant="primary"
                      phx-click="checkout"
                      phx-value-plan_id={plan.id}
                      class="checkout-plan"
                      id={"checkout-#{plan.id}"}
                      style="margin-top:12px;width:100%"
                    >
                      Subscribe
                    </.button>
                    <div
                      :if={writable?(@samen_mount) and not @billing_admin? and not @billing_actor_failed?}
                      class="billing-admin-only"
                      style="margin-top:12px;font-size:12px;color:var(--muted)"
                    >
                      Only an admin can subscribe this workspace to a plan.
                    </div>
                  </div>
                </div>
              </div>

              <div id="payment-method" class="card" style="padding:16px;margin-bottom:20px;display:flex;align-items:center;justify-content:space-between;gap:12px">
                <div>
                  <div style="font-weight:600;color:#3a3b45">Payment method</div>
                  <div style="font-size:12px;color:var(--muted)">
                    Managed on your billing provider's hosted portal — samen never stores card details.
                  </div>
                </div>
                <.button
                  :if={writable?(@samen_mount) and @billing_admin? and payment_method_available?(@customer)}
                  phx-click="manage_payment_method"
                  id="manage-payment-method"
                >
                  Manage payment method
                </.button>
                <span :if={writable?(@samen_mount) and @billing_admin? and not payment_method_available?(@customer) and :customer not in @section_errors} style="font-size:12px;color:var(--muted)">
                  Available after your first subscription.
                </span>
                <span :if={:customer in @section_errors} class="payment-method-unavailable" style="font-size:12px;color:var(--muted)">
                  {Guard.message()}
                </span>
                <span :if={writable?(@samen_mount) and not @billing_admin? and not @billing_actor_failed?} class="billing-admin-only" style="font-size:12px;color:var(--muted)">
                  Only an admin can manage the payment method.
                </span>
              </div>

              <div id="settings-invoice-history">
                <div class="gtitle">
                  <h3>Recent invoices</h3>
                  <span class="n">{length(@recent_invoices.items)}</span>
                  <a href={"#{billing_path(@return_to)}/invoices?org=#{@org_id}"} class="lane" id="view-all-invoices">View all invoices →</a>
                </div>

                <.error_state :if={:invoices in @section_errors} class="settings-invoice-error" body={Guard.message()} retry_event="retry_load" />

                <.empty_state
                  :if={@recent_invoices.items == [] and :invoices not in @section_errors}
                  class="settings-invoice-empty"
                  icon="☰"
                  title="No invoices yet"
                  body="Invoices raised on this workspace appear here with their status and hosted links."
                />

                <.data_table :if={@recent_invoices.items != []}>
                  <:head>
                    <th style="width:24%">Customer</th>
                    <th style="width:16%">Amount</th>
                    <th style="width:14%">Tax</th>
                    <th style="width:14%">Status</th>
                    <th style="width:14%">Due date</th>
                    <th style="width:18%">Links</th>
                  </:head>
                  <tr :for={inv <- @recent_invoices.items} class="settings-invoice-row" id={"settings-invoice-#{inv.id}"}>
                    <td>{render_billing_name(inv.__customer__)}</td>
                    <td style="font-weight:500;color:#3a3b45">{dollars(inv.amount_due_cents || 0)}</td>
                    <td style="color:var(--muted);font-size:12px">{tax_display(inv.tax_amount_cents)}</td>
                    <td><.pill variant={if inv.status == :paid, do: "ok", else: "info"}>{inv.status}</.pill></td>
                    <td style="color:var(--muted);font-size:12px">{format_date(inv.due_date)}</td>
                    <td style="font-size:12px">
                      <a :if={inv.hosted_invoice_url} href={inv.hosted_invoice_url} target="_blank" rel="noopener noreferrer">View invoice</a>
                      <span :if={!inv.hosted_invoice_url} style="color:var(--muted)">—</span>
                    </td>
                  </tr>
                </.data_table>
              </div>
            </div>
          <% else %>
            <div class="wrap" id="billing-settings-empty">
              <.empty_state
                class="billing-not-configured"
                icon="⚠"
                title="Billing is not configured"
                body={not_configured_copy()}
              />
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp billing_path(nil), do: "/billing"
  defp billing_path(return_to) do
    return_to
    |> String.split("/")
    |> Enum.take(2)
    |> Enum.join("/")
    |> case do
      "" -> "/billing"
      path -> path
    end
  end
end
