defmodule Samen.Web.CRM.Live do
  @moduledoc """
  Shared CRM LiveView helpers: mount assignment (re-exported from `Samen.Web.Live`) and the
  CRM sidebar component. The sidebar is HOST-AGNOSTIC — its workspace title / glyph / logo
  gradient come from `mount.labels` (per-host branding) with neutral framework defaults, so
  Driftwood shows "Blue Ridge Logistics / B" and a bare mount shows "Workspace / S". This is
  the ADR-009 rule: vertical-specific COPY is data on the mount, not forked code.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (New/Edit/Delete buttons, composers, modals' submit paths)
  are OFFERED on this mount — tenant plane only (ADR-011 §6.3 posture: an operator does
  not author into a tenant's data; the SAME rule the log-activity composer already used).

  This is UX, not enforcement: the kernel enforces regardless (OrgScope + role gates on
  every write; `Samen.Pii.WriteGuard` rejects an operator-plane plaintext write to any
  vaulted attribute at the Ash write path — MC-1 / Invariant L1). Hiding the affordance
  never substitutes for the write-path red-path tests.
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  @doc """
  Project synced mailbox messages (spec §I1 CRM two-way email sync, T74) onto the
  SAME timeline entry keys the Work `Task` projection uses (ADR-041 §6.1) — so the
  presentational `Samen.UI.Object.timeline/1` is UNCHANGED and one rail carries
  logged activity and real mail together:

    * `:type` is always `:email` (the kit already ships that glyph/label);
    * `:status` is the message DIRECTION (`inbound` / `outbound`) — the two-way
      sync's two legs are legible on the timeline itself;
    * `:subject` / `:body` / `:who` are the 🔒 vault-routed `subject` / `body` /
      `counterparty_address` **exactly as `Samen.Api.PiiResolution` returned them**.
      This module NEVER unwraps a `%Samen.Masked{}` and has no plaintext branch: on
      the operator-without-grant plane those three arrive as `%Masked{}` and render
      `••••` through `Phoenix.HTML.Safe`, never a `vt_*` token.
  """
  def mail_timeline_entries(mail) when is_list(mail) do
    Enum.map(mail, fn m ->
      %{
        id: m.id,
        type: :email,
        subject: Map.get(m, :subject),
        body: Map.get(m, :body),
        status: Map.get(m, :direction),
        at: Map.get(m, :occurred_at) || Map.get(m, :inserted_at),
        who: Map.get(m, :counterparty_address)
      }
    end)
  end

  def mail_timeline_entries(_), do: []

  @doc """
  Merge two already-projected timeline entry lists, newest-first. Entries with no
  timestamp sort last (they are never silently dropped).
  """
  def merge_timeline(entries, more) when is_list(entries) and is_list(more) do
    (entries ++ more)
    |> Enum.sort_by(&timeline_sort_key/1, :desc)
  end

  defp timeline_sort_key(%{at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp timeline_sort_key(%{at: %NaiveDateTime{} = at}),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp timeline_sort_key(_), do: -1

  @doc """
  The composite FULL-NAME form field for CRM person forms (🔒 PII — `full_name` is a
  vault-routed `Samen.Type.FullName`).

  ## Masking (LOAD-BEARING — MC-1 render half on the composite)

  Dispatch is ON THE VALUE, exactly like the kit's `form_field/1`:

    * value is `%Samen.Masked{}` (operator/impersonation plane) → delegate to
      `form_field/1`, whose masked branch renders the read-only `••••` placeholder with
      NO `name` attribute — nothing this field can submit, no token in the DOM.
    * otherwise (tenant plane / a create form with no stored value) → TWO nested
      sub-inputs (`…[full_name][first]` / `…[full_name][last]`) that submit the map
      shape `Samen.Type.FullName.cast_input/2` accepts. The echoed values come from
      `name_part/2`, which reads only a NON-masked struct/map/JSON-string — a
      `%Samen.Masked{}` can never reach the editable branch by construction.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: "Full name"

  def full_name_field(%{field: %Phoenix.HTML.FormField{value: %Samen.Masked{}}} = assigns) do
    ~H"""
    <Samen.UI.form_field field={@field} label={@label} />
    """
  end

  def full_name_field(assigns) do
    errors = Enum.map(assigns.field.errors, &interpolate_error/1)
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <div class={["field", "field-composite", @errors != [] && "field-invalid"]} style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
      <span class="field-label" style="font-size:12px;font-weight:600">{@label}</span>
      <div style="display:flex;gap:8px">
        <input
          type="text"
          id={"#{@field.id}_first"}
          name={"#{@field.name}[first]"}
          value={name_part(@field.value, :first)}
          placeholder="First"
          aria-label="First name"
          aria-invalid={@errors != [] && "true"}
          style="flex:1"
        />
        <input
          type="text"
          id={"#{@field.id}_last"}
          name={"#{@field.name}[last]"}
          value={name_part(@field.value, :last)}
          placeholder="Last"
          aria-label="Last name"
          aria-invalid={@errors != [] && "true"}
          style="flex:1"
        />
      </div>
      <div :if={@errors != []} class="field-errors">
        <p :for={msg <- @errors} class="field-error" style="margin:0;color:var(--bad, #b91c1c);font-size:12px">{msg}</p>
      </div>
    </div>
    """
  end

  # Read one part of a NON-masked full-name value: the cast struct (after validate),
  # a raw map (nested params), the resolver's JSON string (tenant-plane read), or nil
  # (create form). NEVER a %Samen.Masked{} — that shape dispatches to form_field/1 above.
  defp name_part(%Samen.Type.FullName{} = v, part), do: Map.get(v, part)
  defp name_part(%{} = m, part), do: Map.get(m, part) || Map.get(m, to_string(part))

  defp name_part(json, part) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = m} -> Map.get(m, to_string(part))
      _ -> nil
    end
  end

  defp name_part(_, _), do: nil

  defp interpolate_error({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp interpolate_error(msg) when is_binary(msg), do: msg

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: nil
  attr :return_to, :string, default: nil

  @doc """
  The CRM sidebar — workspace header (the RESOLVED current-org name, ADR-013 §4.6) with the
  functional workspace switcher in the header slot + the inherited `module_nav`.
  """
  def crm_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="CRM"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#0E7C5A,#17A06E)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>
      <:search>
        <.search_box org_id={@org_id} placeholder="Search companies, contacts…" />
      </:search>

      <.module_nav org_id={@org_id} active={@active}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "member")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
