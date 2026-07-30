defmodule Samen.Web.Automation.BuilderLive do
  @moduledoc """
  Framework TENANT automation (workflow) BUILDER — `/automation` (ADR-039 §12
  done-criterion 4 UI half; T118), mounted via `Samen.Web.Router.samen_automation_routes/2`
  over the host's Automation-scope `Workflow` (`use Samen.Scopes.Automation`, T39/T40).
  A tenant operator authors, edits, pauses/resumes, and manually runs a workflow
  (trigger → conditions → actions) without ever leaving the tenant plane (INV-2 — see
  `samen_automation_routes/3`'s moduledoc; there is no operator-plane mount of this
  view at all).

  ## Rides T39's engine + T40's action registry — never re-implements them

    * **Conditions** — the attribute picker is sourced LIVE from
      `Samen.Automation.NonPiiPredicates.eligible_names/1` for the workflow's
      `resource_key` (`Samen.Web.Automation.Reads.eligible_attributes/1`). A vault or
      plaintext-PII attribute of the target resource is structurally never an option
      (INV-1's UI half). The SAME write-time oracle runs on every save regardless —
      forging a non-eligible `attribute` directly into `handle_event("add_condition",
      ...)` (bypassing the `<select>`) is refused by the kernel just the same, proven
      by `automation_builder_live_test.exs`'s red-path test.
    * **Actions** — the action-kind picker is sourced LIVE from
      `Samen.Automation.Action.kinds/0` (T39's `notify` + T40's remaining seven) —
      never a hardcoded list, so a host's `config :samen_core, Samen.Automation.Action,
      extra: %{...}` addition shows up with zero builder changes.
    * **Pause/resume** — writes the TENANT `status` switch (`:draft | :active |
      :paused`) through the ordinary `:update` action — the SAME kill-switch column
      family T39/T42 read, never a parallel mechanism (see `Reads.toggle_pause/3`).
    * **Manual "Run now"** — `Samen.Automation.trigger_manual/2`, the SAME dispatch
      pipeline an event/schedule trigger enqueues (see `Reads.run_now/3`).

  ## ADR-042 Class B progressive enhancement

  The workflow list (name/trigger/resource/status/counts) renders FULLY from
  `mount`/`load` — no `phx-click` required to see it (asserted with no connected
  socket by `automation_builder_live_test.exs`). Creating/editing a workflow, adding
  a condition/action, pausing/resuming, and "Run now" are `phx-click`/`phx-submit`
  writes that, per ADR-042, may depend on the live client — proven browser-real
  against T113's socket (`_orch/tasks/T118/work/`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Automation.Live, only: [assign_mount: 2, automation_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Automation.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  use Samen.Web.ListLive,
    resource: Workflow,
    reads: &Samen.Web.Automation.Reads.workflows_page/3,
    sortable: [:name, :status, :trigger_kind],
    filter_fields: [:name],
    default_sort: {:name, :asc}

  @trigger_kinds [{"Resource event", "resource_event"}, {"Schedule", "schedule"}, {"Manual", "manual"}]
  @events [{"(any)", ""}, {"created", "created"}, {"updated", "updated"}, {"destroyed", "destroyed"}]
  @ops [{"equals", "eq"}, {"not equals", "neq"}, {"in", "in"}, {"not in", "not_in"}, {"changed", "changed"}]

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_defaults()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_defaults()
    |> assign(no_org: false, org_id: org_id, action_kinds: Reads.action_kinds())
    |> init_list(mount, scope)
    |> refresh_edit()
  end

  defp ensure_defaults(socket) do
    socket
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:edit_workflow, fn -> nil end)
    |> assign_new(:wf_form, fn -> nil end)
    |> assign_new(:wf_error, fn -> nil end)
    |> assign_new(:cond_error, fn -> nil end)
    |> assign_new(:action_error, fn -> nil end)
    |> assign_new(:run_error, fn -> nil end)
    |> assign_new(:run_ok, fn -> nil end)
    |> assign_new(:condition_form, fn -> blank_condition_form() end)
    |> assign_new(:action_form, fn -> blank_action_form() end)
    |> assign_new(:action_kinds, fn -> [] end)
    |> assign_new(:eligible_attrs, fn -> [] end)
  end

  # Re-read the workflow under edit after any mutation (fresh conditions/actions).
  defp refresh_edit(%{assigns: %{edit_workflow: nil}} = socket), do: socket
  defp refresh_edit(%{assigns: %{edit_workflow: :new}} = socket), do: socket

  defp refresh_edit(%{assigns: %{edit_workflow: wf}} = socket) do
    open_edit(socket, wf.id)
  end

  defp open_edit(socket, id) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.get_workflow(mount, scope, id) do
      nil ->
        assign(socket, edit_workflow: nil, wf_form: nil)

      wf ->
        assign(socket,
          edit_workflow: wf,
          wf_form: to_form(wf_params(wf), as: :workflow),
          eligible_attrs: Reads.eligible_attributes(wf.resource_key)
        )
    end
  end

  # -- CRUD events (list events belong to the ListLive hook) ---------------------

  @impl true
  def handle_event("new_workflow", _params, socket) do
    {:noreply,
     assign(socket,
       edit_workflow: :new,
       wf_form: to_form(blank_wf_params(), as: :workflow),
       wf_error: nil,
       eligible_attrs: []
     )}
  end

  def handle_event("edit_workflow", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(wf_error: nil, cond_error: nil, action_error: nil, run_ok: nil, run_error: nil)
     |> assign(condition_form: blank_condition_form(), action_form: blank_action_form())
     |> open_edit(id)}
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, edit_workflow: nil, wf_form: nil, wf_error: nil)}
  end

  def handle_event("save_workflow", %{"workflow" => params}, socket) do
    {:noreply, save_workflow(socket, socket.assigns.edit_workflow, params)}
  end

  def handle_event("toggle_pause", %{"id" => id}, socket) do
    {:noreply, mutate(socket, &Reads.toggle_pause(&1, &2, id))}
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.get_workflow(mount, scope, id) do
      nil ->
        {:noreply, assign(socket, run_error: "Workflow not found.", run_ok: nil)}

      wf ->
        case Reads.run_now(mount, org_id, wf) do
          {:ok, %{enqueued: true} = result} ->
            {:noreply, assign(socket, run_ok: "Run enqueued (event #{result.event_id}).", run_error: nil)}

          {:error, reason} ->
            {:noreply, assign(socket, run_error: run_error_copy(reason), run_ok: nil)}
        end
    end
  end

  def handle_event("add_condition", %{"condition" => params}, socket) do
    %{edit_workflow: wf} = socket.assigns
    condition = build_condition(params)

    case guarded_write(socket, &Reads.add_condition(&1, &2, wf.id, condition)) do
      {:ok, socket} ->
        {:noreply, socket |> assign(cond_error: nil, condition_form: blank_condition_form()) |> reload()}

      {:error, message, socket} ->
        # The kernel NonPiiPredicates refusal (INV-1) — surfaced verbatim; the
        # condition did NOT persist, whether it came from the picker or not.
        {:noreply, assign(socket, cond_error: message, condition_form: to_form(params, as: :condition))}
    end
  end

  def handle_event("remove_condition", %{"index" => raw_index}, socket) do
    %{edit_workflow: wf} = socket.assigns

    with {index, _} <- Integer.parse(to_string(raw_index)) do
      {:noreply, mutate(socket, &Reads.remove_condition(&1, &2, wf.id, index))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("add_action", %{"action" => params}, socket) do
    %{edit_workflow: wf} = socket.assigns
    action = build_action(params)

    case guarded_write(socket, &Reads.add_action(&1, &2, wf.id, action)) do
      {:ok, socket} ->
        {:noreply, socket |> assign(action_error: nil, action_form: blank_action_form()) |> reload()}

      {:error, message, socket} ->
        {:noreply, assign(socket, action_error: message, action_form: to_form(params, as: :action))}
    end
  end

  def handle_event("remove_action", %{"index" => raw_index}, socket) do
    %{edit_workflow: wf} = socket.assigns

    with {index, _} <- Integer.parse(to_string(raw_index)) do
      {:noreply, mutate(socket, &Reads.remove_action(&1, &2, wf.id, index))}
    else
      _ -> {:noreply, socket}
    end
  end

  # -- write plumbing --------------------------------------------------------------

  defp save_workflow(socket, :new, params) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.create_workflow(mount, scope, wf_attrs(params)) do
      {:ok, wf} ->
        socket
        |> assign(edit_workflow: wf, wf_form: to_form(wf_params(wf), as: :workflow), wf_error: nil)
        |> assign(eligible_attrs: Reads.eligible_attributes(wf.resource_key))
        |> reload()

      {:error, message} ->
        assign(socket, wf_error: message, wf_form: to_form(params, as: :workflow))
    end
  end

  defp save_workflow(socket, %{id: _id}, params) do
    case guarded_write(socket, &Reads.update_workflow(&1, &2, socket.assigns.edit_workflow.id, wf_attrs(params))) do
      {:ok, socket} ->
        socket |> assign(wf_error: nil) |> reload()

      {:error, message, socket} ->
        assign(socket, wf_error: message, wf_form: to_form(params, as: :workflow))
    end
  end

  defp save_workflow(socket, _, _params), do: socket

  # A guarded write: posture-checked (never elevates on an impersonation mount —
  # although this surface never mounts one, see moduledoc), then the kernel-enforced
  # action via the plain tenant scope (no elevation needed — see `Reads` moduledoc).
  defp guarded_write(socket, fun) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if writable?(mount) and org_id != nil do
      case fun.(mount, Mount.scope(mount, org_id)) do
        {:ok, wf} -> {:ok, refresh_edit(assign(socket, edit_workflow: wf))}
        {:error, message} -> {:error, message, socket}
      end
    else
      {:error, "Read-only on this plane.", socket}
    end
  end

  defp mutate(socket, fun) do
    case guarded_write(socket, fun) do
      {:ok, socket} -> socket |> assign(wf_error: nil) |> reload()
      {:error, message, socket} -> assign(socket, wf_error: message)
    end
  end

  defp reload(socket), do: load(socket, socket.assigns.org_id)

  # -- form <-> attrs ---------------------------------------------------------------

  defp blank_wf_params, do: %{"name" => "", "trigger_kind" => "resource_event", "resource_key" => "", "event" => "", "schedule_cron" => ""}

  defp wf_params(wf) do
    %{
      "name" => wf.name || "",
      "trigger_kind" => to_string(wf.trigger_kind || :resource_event),
      "resource_key" => wf.resource_key || "",
      "event" => (wf.event && to_string(wf.event)) || "",
      "schedule_cron" => wf.schedule_cron || ""
    }
  end

  defp wf_attrs(params) do
    %{
      name: trim(params["name"]),
      trigger_kind: safe_enum(params["trigger_kind"], ~w(resource_event schedule manual), :resource_event),
      resource_key: blank_to_nil(params["resource_key"]),
      event: safe_enum_or_nil(params["event"], ~w(created updated destroyed)),
      schedule_cron: blank_to_nil(params["schedule_cron"])
    }
  end

  defp blank_condition_form, do: to_form(%{"attribute" => "", "op" => "eq", "values" => ""}, as: :condition)

  # The bounded condition map the kernel validates at write (`attribute`/`op`/
  # `values` — `Samen.Automation.Condition`'s evaluator shape). Values are
  # comma-separated bounded config scalars, same convention as the flags rule form.
  defp build_condition(params) do
    %{
      "attribute" => String.trim(params["attribute"] || ""),
      "op" => params["op"] || "eq",
      "values" =>
        (params["values"] || "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    }
  end

  defp blank_action_form,
    do: to_form(%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired", "template_key" => "workflow_notify"}, as: :action)

  defp build_action(params) do
    %{
      "kind" => params["kind"] || "notify",
      "recipient" => blank_default(params["recipient"], "owner"),
      "event_type" => blank_default(params["event_type"], "workflow.fired"),
      "template_key" => blank_default(params["template_key"], "workflow_notify")
    }
  end

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(_), do: ""

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp blank_default(v, default), do: blank_to_nil(v) || default

  defp safe_enum(v, allowed, default) when is_binary(v) do
    if v in allowed, do: String.to_existing_atom(v), else: default
  end

  defp safe_enum(_, _allowed, default), do: default

  defp safe_enum_or_nil(v, allowed) when is_binary(v) do
    if v in allowed, do: String.to_existing_atom(v), else: nil
  end

  defp safe_enum_or_nil(_, _allowed), do: nil

  defp run_error_copy(:no_automation_module), do: "Automation is not configured on this host."
  defp run_error_copy(_other), do: "That run could not be enqueued."

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="automation-builder">
      <.app_shell>
        <:sidebar>
          <.automation_sidebar mount={@samen_mount} org_id={@org_id} active={:automation} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Automation" crumbs={crumbs(@samen_mount, @org_id)}>
          <:actions>
            <.button :if={writable?(@samen_mount)} phx-click="new_workflow" id="new-workflow-btn" variant="primary">
              New workflow
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Automation org: {@org_id}</span>

          <div :if={@wf_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="wf-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@wf_error}
            </div>
          </div>

          <div :if={@run_ok} class="wrap" style="margin-bottom:0">
            <div class="card" id="run-ok" style="padding:10px 14px;color:#0a7a3d;font-size:12px">{@run_ok}</div>
          </div>

          <div :if={@run_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="run-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@run_error}
            </div>
          </div>

          <div class="wrap">
            <div id="workflows">
              <div class="gtitle">
                <h3>Workflows</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· trigger → conditions → actions · condition keys are non-PII by construction</span>
              </div>
              <.list_view
                id="workflows-list"
                page={@page}
                state={@list_state}
                row_class="workflow-row"
                filter_placeholder="Filter workflows…"
                empty_text="No workflows yet."
                empty_icon="⚙"
                empty_body="Author a workflow — pick a trigger, add conditions, and choose actions from the automation registry."
              >
                <:head>
                  <.sort_header field={:name} label="Workflow" sort={@list_state.sort} width="24%" />
                  <.sort_header field={:trigger_kind} label="Trigger" sort={@list_state.sort} width="14%" />
                  <th scope="col" style="width:20%">Resource</th>
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="10%" />
                  <th scope="col" style="width:8%">Conditions</th>
                  <th scope="col" style="width:8%">Actions</th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:16%">
                    <span class="sr-only">Actions</span>
                  </th>
                </:head>
                <:row :let={wf}>
                  <td class="wf-name">
                    <div style="font-weight:600;color:#3a3b45">{wf.name}</div>
                  </td>
                  <td class="wf-trigger"><.pill variant="info">{wf.trigger_kind}</.pill></td>
                  <td class="wf-resource" style="color:var(--muted);font-size:11px">{wf.resource_key || "—"}</td>
                  <td class="wf-status">
                    <span class={"pill pill-#{wf.status}"}>{wf.status}</span>
                    <span :if={wf.disabled_by_operator_at} class="pill pill-killed" id={"op-killed-#{wf.id}"}>
                      operator-killed
                    </span>
                  </td>
                  <td class="wf-conditions-count">{length(wf.conditions || [])}</td>
                  <td class="wf-actions-count">{length(wf.actions || [])}</td>
                  <td :if={writable?(@samen_mount)} class="wf-row-actions">
                    <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">
                      <.button phx-click="edit_workflow" phx-value-id={wf.id} id={"edit-#{wf.id}"}>Edit</.button>
                      <.button phx-click="toggle_pause" phx-value-id={wf.id} id={"pause-#{wf.id}"}>
                        {if wf.status == :paused, do: "Resume", else: "Pause"}
                      </.button>
                      <.button phx-click="run_now" phx-value-id={wf.id} id={"run-now-#{wf.id}"}>Run now</.button>
                    </div>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal
            :if={@edit_workflow != nil and writable?(@samen_mount)}
            id="workflow-edit-modal"
            title={modal_title(@edit_workflow)}
            on_cancel="close_edit"
          >
            <.simple_form :let={f} for={@wf_form} id="workflow-form" phx-submit="save_workflow">
              <.form_field field={f[:name]} label="Name" placeholder="Escalate stale opportunities" />
              <.form_field field={f[:trigger_kind]} label="Trigger" type="select" options={trigger_kind_options()} />
              <.form_field
                field={f[:resource_key]}
                label="Target resource (fully-qualified module)"
                placeholder="Driftwood.Crm.Person"
              />
              <.form_field field={f[:event]} label="Event (resource_event only)" type="select" options={event_options()} />
              <.form_field field={f[:schedule_cron]} label="Schedule cron (schedule only)" placeholder="*/15 * * * *" />
              <:actions>
                <.button variant="primary" type="submit">{if @edit_workflow == :new, do: "Create workflow", else: "Save"}</.button>
              </:actions>
            </.simple_form>

            <%= if @edit_workflow != :new do %>
              <div class="gtitle" style="margin-top:14px">
                <h3>Conditions</h3>
                <span class="n">{length(wf_conditions(@edit_workflow))}</span>
                <span class="lane">· AND-gate · non-PII attributes only (write-time refused otherwise)</span>
              </div>

              <table :if={(wf_conditions(@edit_workflow)) != []} class="tbl" id="workflow-conditions">
                <thead>
                  <tr>
                    <th scope="col" style="width:30%">Attribute</th>
                    <th scope="col" style="width:16%">Op</th>
                    <th scope="col" style="width:34%">Values</th>
                    <th scope="col" style="width:12%"><span class="sr-only">Remove</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{c, idx} <- Enum.with_index(wf_conditions(@edit_workflow))} class="condition-row" id={"condition-#{idx}"}>
                    <td class="condition-attribute" style="font-weight:500">{cond_field(c, "attribute")}</td>
                    <td class="condition-op" style="color:var(--muted)">{cond_field(c, "op")}</td>
                    <td class="condition-values">{cond_values(c)}</td>
                    <td>
                      <.button phx-click="remove_condition" phx-value-index={idx}>Remove</.button>
                    </td>
                  </tr>
                </tbody>
              </table>

              <div :if={@cond_error} class="card form-error" id="condition-error" style="padding:10px 14px;margin:8px 0;color:var(--bad, #b91c1c);font-size:12px">
                {@cond_error}
              </div>

              <.simple_form :let={f} for={@condition_form} id="condition-form" phx-submit="add_condition">
                <.form_field
                  field={f[:attribute]}
                  label="Attribute (non-PII, eligible only)"
                  type="select"
                  options={eligible_attr_options(@eligible_attrs)}
                />
                <.form_field field={f[:op]} label="Operator" type="select" options={op_options()} />
                <.form_field field={f[:values]} label="Values (comma-separated)" placeholder="open, pending" />
                <:actions>
                  <.button variant="primary" type="submit" id="add-condition-btn">Add condition</.button>
                </:actions>
              </.simple_form>

              <p :if={@eligible_attrs == []} style="margin:6px 0 14px;font-size:11px;color:var(--muted)" id="no-eligible-attrs">
                No eligible (non-PII) attributes for this resource yet — set a valid "Target resource" above.
              </p>

              <div class="gtitle" style="margin-top:18px">
                <h3>Actions</h3>
                <span class="n">{length(wf_actions(@edit_workflow))}</span>
                <span class="lane">· ordered · read from the T39/T40 action registry</span>
              </div>

              <table :if={(wf_actions(@edit_workflow)) != []} class="tbl" id="workflow-actions">
                <thead>
                  <tr>
                    <th scope="col" style="width:16%">Kind</th>
                    <th scope="col" style="width:20%">Recipient</th>
                    <th scope="col" style="width:26%">Event type</th>
                    <th scope="col" style="width:26%">Template</th>
                    <th scope="col" style="width:12%"><span class="sr-only">Remove</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{a, idx} <- Enum.with_index(wf_actions(@edit_workflow))} class="action-row" id={"action-#{idx}"}>
                    <td class="action-kind" style="font-weight:500">{cond_field(a, "kind")}</td>
                    <td class="action-recipient">{cond_field(a, "recipient")}</td>
                    <td class="action-event-type">{cond_field(a, "event_type")}</td>
                    <td class="action-template">{cond_field(a, "template_key")}</td>
                    <td>
                      <.button phx-click="remove_action" phx-value-index={idx}>Remove</.button>
                    </td>
                  </tr>
                </tbody>
              </table>

              <div :if={@action_error} class="card form-error" id="action-error" style="padding:10px 14px;margin:8px 0;color:var(--bad, #b91c1c);font-size:12px">
                {@action_error}
              </div>

              <.simple_form :let={f} for={@action_form} id="action-form" phx-submit="add_action">
                <.form_field field={f[:kind]} label="Action kind" type="select" options={action_kind_options(@action_kinds)} />
                <.form_field field={f[:recipient]} label="Recipient" placeholder="owner" />
                <.form_field field={f[:event_type]} label="Event type" placeholder="workflow.fired" />
                <.form_field field={f[:template_key]} label="Template key" placeholder="workflow_notify" />
                <:actions>
                  <.button variant="primary" type="submit" id="add-action-btn">Add action</.button>
                </:actions>
              </.simple_form>

              <div style="display:flex;gap:8px;margin-top:16px">
                <.button phx-click="toggle_pause" phx-value-id={@edit_workflow.id} id="modal-pause-btn">
                  {if @edit_workflow.status == :paused, do: "Resume", else: "Pause"}
                </.button>
                <.button phx-click="run_now" phx-value-id={@edit_workflow.id} id="modal-run-now-btn">Run now</.button>
                <.button type="button" phx-click="close_edit">Done</.button>
              </div>
            <% end %>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id), do: [CurrentOrg.name(mount, org_id), "Settings", "Automation"]

  defp modal_title(:new), do: "New workflow"
  defp modal_title(%{name: name}) when is_binary(name) and name != "", do: name
  defp modal_title(_), do: "Workflow"

  defp trigger_kind_options, do: @trigger_kinds
  defp event_options, do: @events
  defp op_options, do: @ops

  defp eligible_attr_options([]), do: [{"(none — set a target resource)", ""}]
  defp eligible_attr_options(attrs), do: Enum.map(attrs, &{&1, &1})

  defp action_kind_options([]), do: [{"notify", "notify"}]
  defp action_kind_options(kinds), do: Enum.map(kinds, &{&1, &1})

  defp cond_field(m, key) when is_map(m), do: to_string(m[key] || m[String.to_atom(key)] || "—")
  defp cond_field(_, _), do: "—"

  defp cond_values(m) when is_map(m) do
    case m["values"] || m[:values] do
      values when is_list(values) -> Enum.map_join(values, ", ", &to_string/1)
      _ -> "—"
    end
  end

  defp cond_values(_), do: "—"

  # Named helpers (rather than inline `@edit_workflow.conditions || []` repeated at
  # each call site) — Elixir's type checker narrows `edit_workflow.conditions` as
  # non-nil after the FIRST inline `|| []` occurrence in this function, which then
  # flags every later repeat as dead code under `--warnings-as-errors`. Routing
  # every access through one function sidesteps the cross-occurrence narrowing.
  defp wf_conditions(%{conditions: conditions}), do: conditions || []
  defp wf_conditions(_), do: []

  defp wf_actions(%{actions: actions}), do: actions || []
  defp wf_actions(_), do: []
end
