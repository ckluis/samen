defmodule DriftwoodWeb.CrmContactsLive do
  @moduledoc """
  CRM / Contacts page — 🔒 PII: person name, email, phone.

  Reads `Driftwood.Crm.Person` through `Driftwood.CrmReads.contacts/1`.
  `full_name`, `emails`, and `phones` are vault-routed PII fields. The resolver
  (`Samen.Api.PiiResolution`) is threaded through `CrmReads.contacts/1`:

    * TENANT plane (`plane: :tenant`) — the org reads its OWN contacts in CLEAR.
      No reveal grant needed (tenant-as-owner rule; §external-surface :707).
    * OPERATOR / impersonation plane (`plane: :operator` + impersonation marker) —
      the same fields render `%Masked{}` (→ ••••). The resolver is the SINGLE vault
      chokepoint; this page introduces NO plaintext path that bypasses it.

  The page renders whatever value the resolver returns. A `%Masked{}` renders ••••
  via `Phoenix.HTML.Safe` — the UIKit data_table is a dumb renderer of already-
  resolved values (ADR-008 masking invariant).

  MASKING INVARIANT: this LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER
  pattern-matches a vault token out of a `%Masked{}`, and NEVER introduces a
  "show plaintext" code path. Plaintext only reaches a cell if `CrmReads.contacts/1`
  already resolved it through the shared resolver.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.CrmReads

  @impl true
  def mount(params, _session, socket) do
    org_id = Map.get(params, "org")
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket, no_org: true, org_id: nil, contacts: [])
  end

  def load(socket, org_id) do
    scope = crm_scope(org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      contacts: CrmReads.contacts(scope),
      company_names: company_name_map(scope)
    )
  end

  # id → company name, for the contacts' Company column. Own rescue so a
  # company-read failure never blanks the contacts list.
  defp company_name_map(scope) do
    CrmReads.companies(scope) |> Map.new(fn c -> {c.id, c.name} end)
  rescue
    _ -> %{}
  end

  # A tenant-member scope for CRM contacts: plane: :tenant so the org reads its OWN
  # contacts' PII in CLEAR through the PiiResolution resolver.
  @doc false
  def crm_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  # An OPERATOR impersonation scope — used in tests to assert masking.
  @doc false
  def operator_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "operator:impersonation",
        org_id: org_id,
        role: :member,
        kind: :operator,
        plane: :operator,
        impersonation: %{session_id: "test-session"}
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-contacts">
      <.app_shell>
        <:sidebar>
          {crm_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Contacts" crumbs={["Blue Ridge Logistics", "CRM", "Contacts"]}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New contact
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="wrap">
            <div id="contacts">
              <div class="gtitle">
                <h3>Contacts</h3>
                <span class="n">{length(@contacts)}</span>
                <span class="lane">· name / email / phone via PiiResolution · your org in the clear</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:24%">Name</th>
                  <th style="width:22%">Email</th>
                  <th style="width:16%">Phone</th>
                  <th style="width:22%">Company</th>
                  <th style="width:16%">Title</th>
                </:head>
                <tr :for={p <- @contacts} class="contact-row" id={"contact-#{p.id}"}>
                  <td class="p-name">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div
                        class="av"
                        style="width:28px;height:28px;border-radius:50%;background:#DDE7F5;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"
                      >
                        {contact_initials(p.full_name, p.display_name)}
                      </div>
                      <span class="p-full-name" style="font-weight:500;color:#3a3b45">
                        {render_full_name(p.full_name, p.display_name)}
                      </span>
                    </div>
                  </td>
                  <td class="p-email" style="font-size:12px;color:var(--muted)">
                    {render_email(p.emails)}
                  </td>
                  <td class="p-phone" style="font-size:12px;color:var(--muted)">
                    {render_phone(p.phones)}
                  </td>
                  <td class="p-company" style="color:var(--muted)">{(p.company_id && Map.get(Map.get(assigns, :company_names, %{}), p.company_id)) || "—"}</td>
                  <td class="p-title" style="color:var(--muted);font-size:12px">{p.job_title || "—"}</td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------
  #
  # These helpers render ALREADY-RESOLVED values from PiiResolution. They NEVER
  # unwrap a %Masked{} or call the vault. A %Masked{} is returned AS-IS so it
  # renders •••• through Phoenix.HTML.Safe. Only a plaintext string is reshaped.

  # Render the full_name field (a JSON-encoded FullName struct OR %Masked{}).
  defp render_full_name(%Samen.Masked{} = masked, _display_name), do: masked

  defp render_full_name(name, _display_name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_full_name(nil, display_name) when is_binary(display_name), do: display_name
  defp render_full_name(nil, _display_name), do: "—"
  defp render_full_name(other, _display_name), do: other

  # Initials for the avatar — uses the resolved full_name OR falls back to display_name.
  defp contact_initials(%Samen.Masked{}, _display_name), do: "··"

  defp contact_initials(name, _display_name) when is_binary(name) do
    label =
      case Jason.decode(name) do
        {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
        _ -> name
      end

    label
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp contact_initials(nil, display_name) when is_binary(display_name) do
    display_name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp contact_initials(_, _), do: "??"

  # Render the first email from the emails list (a list of %{label, address} maps, OR %Masked{}).
  defp render_email(%Samen.Masked{} = masked), do: masked

  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  # Tenant plane: the resolver returns the composite as decrypted JSON text.
  defp render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      _ -> "—"
    end
  end

  defp render_email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  defp render_email(_), do: "—"

  # Render the first phone from the phones list (a list of %{label, number} maps, OR %Masked{}).
  defp render_phone(%Samen.Masked{} = masked), do: masked

  defp render_phone(%Samen.Type.Phones{entries: entries}), do: render_phone(entries)

  # Tenant plane: the resolver returns the composite as decrypted JSON text.
  defp render_phone(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_phone(list)
      _ -> "—"
    end
  end

  defp render_phone(phones) when is_list(phones) do
    case List.first(phones) do
      %{"number" => num} -> num
      %{number: num} -> num
      _ -> "—"
    end
  end

  defp render_phone(_), do: "—"

  # Shared CRM sidebar — active on the contacts page.
  defp crm_sidebar(assigns) do
    ~H"""
    <.sidebar
      title="Blue Ridge Logistics"
      subtitle="CRM"
      logo="B"
      logo_style="background:linear-gradient(150deg,#0E7C5A,#17A06E)"
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search companies, contacts…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={:crm_contacts} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">RM</div>
          <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
