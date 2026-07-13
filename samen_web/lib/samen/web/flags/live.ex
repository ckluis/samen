defmodule Samen.Web.Flags.Live do
  @moduledoc """
  Shared FEATURE-FLAG LiveView helpers (WS-B B6; ADR-020 §2 decision 1 — the admin
  UI half of the flag engine): mount assignment (re-exported from `Samen.Web.Live`),
  the A3 `writable?/1` posture, the flags sidebar, and the small shared render
  helpers (decision pill, rules table) both planes use.

  ## Two-plane posture (design G6 §3.5)

  The SAME kernel `FeatureFlag` rows power both planes; only the mount differs:

    * **Tenant** — `Samen.Web.Flags.SettingsLive` over the org's OWN flags
      (`samen_flags_routes/2`); toggle / ramp / targeting rules, gated `admin` by the
      KERNEL policy (`OrgScope` + `RoleAtLeast :admin`) — `writable?/1` is UI posture
      only.
    * **Operator** — `Samen.Web.Operator.FlagAdminLive` over the operator org's own
      flag rows (the PLATFORM flags — tenant plane of the operator org, writable),
      plus the kill switch and per-tenant-org evaluated state.

  An impersonation (`plane: :operator`) mount is read-only UI on either surface;
  enforcement stays in the kernel Ash policy, never here.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether write AFFORDANCES (toggle / ramp / rules / kill switch) are OFFERED on this
  mount — tenant plane only (the A3 posture shared by every module `Live`). POSTURE
  only: the kernel enforces regardless (`OrgScope` + `RoleAtLeast :admin` on every
  flag write; `NonPiiTargeting` refuses PII-keyed rules at the write boundary).
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :active, :atom, default: :flags
  attr :return_to, :string, default: nil

  @doc "The tenant flags sidebar — workspace header + the Settings nav group."
  def flags_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Settings"
      logo={Mount.label(@mount, :glyph, "S")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#3B4CCA,#5B6EE8)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <.nav_group label="Settings">
        <.nav_item label="Feature flags" href={Mount.label(@mount, :flags_path, "/flags")} active={@active == :flags}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M4 21V4" /><path d="M4 4h12l-2 4 2 4H4" />
            </svg>
          </:icon>
        </.nav_item>
      </.nav_group>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#DDE2F5;color:#3B4CCA">{Mount.label(@mount, :user_initials, "S")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Signed in")}</b><span>{Mount.label(@mount, :user_role, "admin")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end

  attr :decision, :any, required: true, doc: "a %Samen.FeatureFlags.Decision{} (bounded, non-PII)"

  @doc """
  Render an evaluated-state pill for a `%Decision{}` — `on`/`off` + the bounded
  precedence reason (`kill_switch` / `targeted` / `rollout_in` / …). Every field is
  a boolean/atom by construction (safe to render; no PII path).
  """
  def decision_pill(assigns) do
    ~H"""
    <span class="flag-decision" style="display:inline-flex;align-items:center;gap:6px">
      <.pill variant={if @decision.on, do: "ok", else: "mut"}>
        {if @decision.on, do: "on", else: "off"}
      </.pill>
      <span class="flag-reason" style="font-size:11px;color:var(--muted)">{@decision.reason}</span>
    </span>
    """
  end

  attr :rules, :list, required: true, doc: "the flag's raw target_rules jsonb list"
  attr :writable, :boolean, default: false
  attr :remove_event, :string, default: "remove_rule"

  @doc """
  The targeting-rules table shared by both planes' edit modals: one row per rule
  (attribute · op · values · then) + a remove affordance when writable. Rules are
  bounded config maps (non-PII keys enforced at write — RP-F3); values render as
  plain config strings.
  """
  def rules_table(assigns) do
    ~H"""
    <table :if={@rules != []} class="tbl" id="flag-rules">
      <thead>
        <tr>
          <th scope="col" style="width:26%">Attribute</th>
          <th scope="col" style="width:16%">Op</th>
          <th scope="col" style="width:32%">Values</th>
          <th scope="col" style="width:14%">Then</th>
          <th :if={@writable} scope="col" style="width:12%"><span class="sr-only">Remove</span></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{rule, idx} <- Enum.with_index(@rules)} class="rule-row" id={"rule-#{idx}"}>
          <td class="rule-attribute" style="font-weight:500">{rule_field(rule, :attribute)}</td>
          <td class="rule-op" style="color:var(--muted)">{rule_field(rule, :op)}</td>
          <td class="rule-values">{rule_values(rule)}</td>
          <td class="rule-then">{rule_field(rule, :then)}</td>
          <td :if={@writable}>
            <.button phx-click={@remove_event} phx-value-index={idx}>Remove</.button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp rule_field(rule, key) when is_map(rule),
    do: to_string(rule[to_string(key)] || rule[key] || "—")

  defp rule_field(_rule, _key), do: "—"

  defp rule_values(rule) when is_map(rule) do
    case rule["values"] || rule[:values] do
      values when is_list(values) -> Enum.map_join(values, ", ", &to_string/1)
      _ -> "—"
    end
  end

  defp rule_values(_), do: "—"
end
