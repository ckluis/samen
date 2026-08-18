defmodule Samen.Web.AI.CrmLive do
  @moduledoc """
  Surface 3/5 — the D6 CRM-AI helpers (timeline summary · inbound classify · next-step
  recommend · sequence draft) on a named CRM record, PLUS the masked grounding PREVIEW that
  makes INV-7 visible on the UI: the record the AI grounds on is read ORG-SCOPED
  (`Samen.Web.AI.Server.crm_preview/4`, hard `org_id == ^org` from the trusted scope) and
  resolved through `Samen.Api.PiiResolution` on the mount's plane. A vault-routed 🔒 field
  renders `••••` on the operator plane, clear on the tenant plane — the standard three-proof
  masking discipline (`ai_crm_masking_test.exs`). Nothing here unwraps a `%Samen.Masked{}`;
  the AI call itself masks by construction inside `Samen.AI.Crm` → `Samen.AI.Chokepoint`.

  The CRM resource the surface grounds on is the host-configured `:ai_crm_resource` mount
  label (the `flags_namespace` precedent) — an unset label renders an honest empty state.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, name: 2]
  import Samen.Web.AI.Components

  alias Samen.Web.AI.Server
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)
    {:ok, load(socket, org_id, id: params["id"] || "")}
  end

  @doc "The framework page-load seam."
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    resource = crm_resource(mount)
    id = Keyword.get(opts, :id, "")

    preview =
      if org_id && resource && id != "",
        do: Server.crm_preview(mount, org_id, resource, id),
        else: nil

    socket =
      socket
      |> Phoenix.Component.assign(:org_id, org_id)
      |> Phoenix.Component.assign(:crm_resource, resource)
      |> Phoenix.Component.assign(:id, id)
      |> Phoenix.Component.assign(:helper, Keyword.get(opts, :helper, :summarize_timeline))
      |> Phoenix.Component.assign(:input, Keyword.get(opts, :input, ""))
      |> Phoenix.Component.assign(:labels, Keyword.get(opts, :labels, ""))
      |> Phoenix.Component.assign(:preview, preview)
      |> Phoenix.Component.assign(:result, nil)

    if Keyword.get(opts, :run, false),
      do: Phoenix.Component.assign(socket, :result, run(socket.assigns)),
      else: socket
  end

  @impl true
  def handle_event("run", %{"helper" => helper} = params, socket) do
    {:noreply,
     load(socket, socket.assigns.org_id,
       id: Map.get(params, "record_id", ""),
       helper: safe_helper(helper),
       input: Map.get(params, "input", ""),
       labels: Map.get(params, "labels", ""),
       run: true
     )}
  end

  defp run(%{org_id: nil}), do: nil

  defp run(assigns) do
    params = if assigns.labels == "", do: %{}, else: %{labels: assigns.labels}

    Server.crm_run(
      assigns.samen_mount,
      assigns.org_id,
      assigns.helper,
      assigns.crm_resource,
      assigns.id,
      assigns.input,
      params
    )
  end

  defp crm_resource(%Mount{} = mount), do: Mount.label(mount, :ai_crm_resource, nil)
  defp crm_resource(_), do: nil

  defp safe_helper(h) when is_binary(h),
    do: Enum.find(Server.crm_helpers(), :summarize_timeline, &(Atom.to_string(&1) == h))

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:crm} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · CRM" crumbs={["AI", "CRM"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:crm} base={ai_base(@samen_mount)} />

      <%= cond do %>
        <% is_nil(@org_id) -> %>
          <.no_org_card mount={@samen_mount} />
        <% is_nil(@crm_resource) -> %>
          <div class="pane" style="padding:16px">
            <.empty_state
              title="No CRM resource configured"
              body="Set the :ai_crm_resource mount label to the CRM object this surface grounds on."
              icon="◇"
            />
          </div>
        <% true -> %>
          <div class="pane" style="display:flex;flex-direction:column;gap:16px;padding:16px">
            <form phx-submit="run" class="card" style="display:flex;flex-direction:column;gap:10px;padding:16px">
              <label style="font-size:13px;font-weight:600">CRM record id</label>
              <input type="text" name="record_id" id="ai-crm-id" value={@id} placeholder="a record id in this org" />

              <label style="font-size:13px;font-weight:600">Helper</label>
              <select name="helper" id="ai-crm-helper">
                <option :for={h <- Server.crm_helpers()} value={h} selected={h == @helper}>{h}</option>
              </select>

              <label style="font-size:13px;font-weight:600">Free text (classify input / extra instruction)</label>
              <textarea name="input" id="ai-crm-input" rows="3">{@input}</textarea>

              <label style="font-size:13px;font-weight:600">Classify labels (optional)</label>
              <input type="text" name="labels" id="ai-crm-labels" value={@labels} />

              <div><.button variant="primary" type="submit">Run</.button></div>
            </form>

            <.crm_preview_card :if={@preview} preview={@preview} />
            <.ai_result :if={@result} result={@result} id="ai-crm-result" />
          </div>
      <% end %>
    </.app_shell>
    """
  end

  # The masked grounding preview — the field the AI grounds on, rendered on the caller's plane.
  attr :preview, :any, required: true

  defp crm_preview_card(%{preview: {:error, _}} = assigns) do
    ~H"""
    <div class="card" id="ai-crm-preview" data-state="not_found" style="padding:16px">
      <.pill variant="mut">Record not found in this org</.pill>
    </div>
    """
  end

  defp crm_preview_card(%{preview: {:ok, fields}} = assigns) do
    assigns = assign(assigns, :fields, fields)

    ~H"""
    <div class="card" id="ai-crm-preview" data-state="ok" style="padding:16px;display:flex;flex-direction:column;gap:6px">
      <div style="font-size:12px;color:var(--muted)">Grounding on this record (vault fields masked by plane):</div>
      <div class="ai-preview-row"><b>Name:</b> <span id="ai-preview-full-name">{pii(Map.get(@fields, :full_name))}</span></div>
      <div class="ai-preview-row"><b>Email:</b> <span id="ai-preview-email">{email(Map.get(@fields, :emails))}</span></div>
    </div>
    """
  end

  # Masking-aware formatters: a `%Samen.Masked{}` is handed back VERBATIM (renders `••••`),
  # never unwrapped; a clear value is formatted for display. (INV-1 — the kit adds no unmask.)
  defp pii(%Samen.Masked{} = m), do: m

  defp pii(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => f, "last" => l}} -> String.trim("#{f} #{l}")
      _ -> name
    end
  end

  defp pii(%{first: f, last: l}), do: String.trim("#{f} #{l}")
  defp pii(nil), do: "—"
  defp pii(other), do: inspect(other)

  defp email(%Samen.Masked{} = m), do: m
  defp email(%{entries: entries}), do: email(entries)

  defp email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> email(list)
      _ -> "—"
    end
  end

  defp email(list) when is_list(list) do
    case List.first(list) do
      %{"address" => a} -> a
      %{address: a} -> a
      _ -> "—"
    end
  end

  defp email(_), do: "—"
end
