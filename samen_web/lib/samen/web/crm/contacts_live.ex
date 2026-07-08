defmodule Samen.Web.CRM.ContactsLive do
  @moduledoc """
  Framework CRM / Contacts page — 🔒 PII: person name, email, phone (ADR-009).

  Reads the host's `<namespace>.Person` via `Samen.Web.CRM.Reads.contacts/2`. `full_name`,
  `emails`, `phones` are vault-routed PII resolved through `Samen.Api.PiiResolution`:

    * TENANT plane — the org reads its OWN contacts in CLEAR.
    * OPERATOR / impersonation plane — the SAME fields render `%Masked{}` (→ ••••). The
      resolver is the SINGLE vault chokepoint; this page introduces NO plaintext bypass.

  The page renders whatever value the resolver returns. A `%Samen.Masked{}` renders `••••`
  via `Phoenix.HTML.Safe`. This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a
  vault token out of a `%Masked{}`, and has NO "show plaintext" branch.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
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
    assign(socket, no_org: true, org_id: nil, contacts: [], company_names: %{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      contacts: Reads.contacts(mount, scope),
      company_names: company_name_map(mount, scope)
    )
  end

  defp company_name_map(mount, scope) do
    Reads.companies(mount, scope) |> Map.new(fn c -> {c.id, c.name} end)
  rescue
    _ -> %{}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-contacts">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_contacts} />
        </:sidebar>

        <.topbar title="Contacts" crumbs={crumbs(@samen_mount, "Contacts")}>
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
                <span class="lane">· name / email / phone via PiiResolution · {plane_note(@samen_mount)}</span>
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
                      <div class="av" style="width:28px;height:28px;border-radius:50%;background:#DDE7F5;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
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
                  <td class="p-company" style="color:var(--muted)">{(p.company_id && Map.get(@company_names, p.company_id)) || "—"}</td>
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
  # These helpers render ALREADY-RESOLVED values from PiiResolution. They NEVER unwrap a
  # %Masked{} or call the vault. A %Masked{} is returned AS-IS so it renders •••• through
  # Phoenix.HTML.Safe. Only a plaintext string is reshaped.

  defp crumbs(mount, leaf), do: [Mount.label(mount, :crumb_root, "Workspace"), "CRM", leaf]

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

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

  defp contact_initials(%Samen.Masked{}, _display_name), do: "··"

  defp contact_initials(name, _display_name) when is_binary(name) do
    label =
      case Jason.decode(name) do
        {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
        _ -> name
      end

    initials(label)
  end

  defp contact_initials(nil, display_name) when is_binary(display_name), do: initials(display_name)
  defp contact_initials(_, _), do: "??"

  defp initials(label) do
    label
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp render_email(%Samen.Masked{} = masked), do: masked
  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

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

  defp render_phone(%Samen.Masked{} = masked), do: masked
  defp render_phone(%Samen.Type.Phones{entries: entries}), do: render_phone(entries)

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
end
