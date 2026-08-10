defmodule Samen.Web.AI.Components do
  @moduledoc """
  Shared chrome + the LOAD-BEARING honesty renderers for the tenant-plane AI UI kit (T155).

  This kit is a tenant-FACING surface, so the keyless/fail-honest signposting matters most
  here (ADR-043 §4): a tenant must NEVER be misled into thinking simulated output is a real
  model result, and an unconfigured plane must render the `Samen.AI.configuration_hint/0`
  path VERBATIM — never a fabricated confident answer.

  `ai_result/1` is the single honesty chokepoint every surface renders its outcome through:

    * `{:ok, %Samen.AI.Completion{simulated: true}}` — a KEYLESS/deterministic result. Renders
      a loud "SIMULATED — not a real model" badge next to the text. The flag is read from the
      T152 `%Completion{}.simulated` field (stamped by construction at the ONE provider site,
      `Samen.AI.Chokepoint`) — NEVER parsed from `:text`. Patch 139 flips this badge and a
      named test fails.
    * `{:ok, %Samen.AI.Completion{simulated: false}}` — a genuine live-model result. Renders a
      neutral "live model" badge. The kit never marks a live output simulated.
    * `{:error, :not_configured}` — renders `Samen.AI.configuration_hint/0` VERBATIM in a
      code block, framed as "no provider wired — this is not an answer". No fabricated text.
      Patch 140 replaces the hint with a fake answer and a named test fails.
    * `{:error, :unauthorized}` — the analytics token-blind gate (T144): honest "requires
      platform/operator authority", never a fabricated aggregate.
    * `{:error, :pii_egress_refused}` — the chokepoint refused the payload (INV-7); honest.
    * any other `{:error, _}` — honest error, payload-free (EG6).
  """
  use Phoenix.Component

  import Samen.UI, only: [pill: 1, nav_group: 1, nav_item: 1]

  alias Samen.AI.Completion
  alias Samen.Web.AI.Server

  @doc "The AI kit mount path prefix for this host (label `:ai_path`, default `/ai`)."
  def ai_base(%Samen.Web.Mount{} = mount), do: Samen.Web.Mount.label(mount, :ai_path, "/ai")

  @doc """
  Whether the analytics ask-box INPUT is offered on this mount (M4 dogfood fix — an
  honest UI POSTURE, mirroring `Samen.Web.CRM.Live.writable?/1`'s tenant/operator
  plane split; this is NOT a security gate and does not touch T144).

  The real authorization is `Samen.AI.Analytics.ask/4`'s deny-by-default
  platform/operator capability check (T144) — unchanged, still enforced server-side
  on every submit regardless of what this function returns. But on a TENANT-plane
  mount that check refuses `{:error, :unauthorized}` deterministically, before any
  row is read, for EVERY question — so a live-looking input + Ask button that can
  never once succeed is a dead tab (a tenant types, submits, and always bounces).
  `AnalyticsLive` renders the SAME honest `ai_result/1` `:unauthorized` card
  up front instead, with no input to type into — never a weakened tenant path, never
  a tempting dead-end.
  """
  def analytics_ask_offered?(%Samen.Web.Mount{plane: %{kind: :operator}}), do: true
  def analytics_ask_offered?(_), do: false

  @doc "The five AI kit surfaces, in nav order: `{kind, label, sub_path}`."
  def surfaces do
    [
      {:verbs, "Verbs", ""},
      {:search, "Semantic search", "/search"},
      {:crm, "CRM AI", "/crm"},
      {:analytics, "Analytics", "/analytics"},
      {:support, "Support draft", "/support"}
    ]
  end

  @doc "The AI-kit sidebar nav (the five surfaces) — the sidebar inner block for every AI page."
  attr :active, :atom, required: true
  attr :base, :string, default: "/ai"

  def ai_sidebar_nav(assigns) do
    ~H"""
    <.nav_group label="AI">
      <.nav_item
        :for={{kind, label, sub} <- Samen.Web.AI.Components.surfaces()}
        href={@base <> sub}
        label={label}
        active={@active == kind}
      />
    </.nav_group>
    """
  end

  @doc "The AI-kit tab bar (the five surfaces). `active` is the current surface kind atom."
  attr :active, :atom, required: true
  attr :base, :string, default: "/ai"

  def ai_tabs(assigns) do
    ~H"""
    <div class="tabs" id="ai-kit-tabs">
      <a
        :for={{kind, label, sub} <- Samen.Web.AI.Components.surfaces()}
        href={@base <> sub}
        class={@active == kind && "on"}
        id={"ai-tab-#{kind}"}
      >
        {label}
      </a>
    </div>
    """
  end

  @doc """
  The honest outcome renderer — the single place a completion/error becomes DOM. See the
  moduledoc: SIMULATED vs live is signposted from the T152 flag; `:not_configured` renders
  the configuration_hint verbatim; nothing fabricates a confident answer.
  """
  attr :result, :any, required: true, doc: "the {:ok, Completion} | {:error, term} to render"
  attr :id, :string, default: "ai-result"

  def ai_result(%{result: {:ok, %Completion{simulated: true} = c}} = assigns) do
    assigns = assign(assigns, :completion, c)

    ~H"""
    <div class="card ai-result ai-result-simulated" id={@id} data-simulated="true">
      <div class="ai-result-head" style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <.pill variant="warn"><span id={"#{@id}-badge"}>SIMULATED — not a real model</span></.pill>
        <span style="color:var(--muted);font-size:12px">
          keyless/deterministic output; wire a provider for a real model result
        </span>
      </div>
      <pre class="ai-result-text" id={"#{@id}-text"} style="white-space:pre-wrap;margin:0">{@completion.text}</pre>
    </div>
    """
  end

  def ai_result(%{result: {:ok, %Completion{simulated: false} = c}} = assigns) do
    assigns = assign(assigns, :completion, c)

    ~H"""
    <div class="card ai-result ai-result-live" id={@id} data-simulated="false">
      <div class="ai-result-head" style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <.pill variant="ok"><span id={"#{@id}-badge"}>Live model</span></.pill>
        <span :if={@completion.model} style="color:var(--muted);font-size:12px">{@completion.model}</span>
      </div>
      <pre class="ai-result-text" id={"#{@id}-text"} style="white-space:pre-wrap;margin:0">{@completion.text}</pre>
    </div>
    """
  end

  # A SIMULATED draft (keyless/deterministic provider) MUST carry the same loud "SIMULATED
  # — not a real model" badge every other AI surface renders — `draft_sequence` preserves
  # the T152 `:simulated` flag through its plain-map conversion (`Samen.AI.Crm`), so a
  # fake-confident outreach draft is NEVER laundered as a neutral "Draft" (the T155-missed
  # honesty hole). This clause is ordered BEFORE the neutral-draft clause so a simulated
  # draft always matches here first; drop the flag and the neutral clause fires (a named
  # honesty test flips).
  def ai_result(%{result: {:ok, %{status: :draft, body: body, simulated: true}}} = assigns) do
    assigns = assign(assigns, :body, body)

    ~H"""
    <div class="card ai-result ai-result-draft ai-result-simulated" id={@id} data-simulated="true">
      <div class="ai-result-head" style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <.pill variant="warn"><span id={"#{@id}-badge"}>SIMULATED — not a real model</span></.pill>
        <span style="color:var(--muted);font-size:12px">
          keyless/deterministic draft; wire a provider for a real model result
        </span>
      </div>
      <pre class="ai-result-text" id={"#{@id}-text"} style="white-space:pre-wrap;margin:0">{@body}</pre>
    </div>
    """
  end

  # A live/genuine draft-sequence surface returns a plain map, not a Completion — treat it
  # as live text (it is the caller's own composed draft, not a model claim of truth).
  def ai_result(%{result: {:ok, %{status: :draft, body: body}}} = assigns) do
    assigns = assign(assigns, :body, body)

    ~H"""
    <div class="card ai-result ai-result-draft" id={@id} data-simulated="draft">
      <div class="ai-result-head" style="margin-bottom:8px">
        <.pill variant="info"><span id={"#{@id}-badge"}>Draft</span></.pill>
      </div>
      <pre class="ai-result-text" id={"#{@id}-text"} style="white-space:pre-wrap;margin:0">{@body}</pre>
    </div>
    """
  end

  def ai_result(%{result: {:error, :not_configured}} = assigns) do
    ~H"""
    <div class="card ai-result ai-result-not-configured" id={@id} data-state="not_configured">
      <div class="ai-result-head" style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <.pill variant="bad"><span id={"#{@id}-badge"}>No AI provider wired</span></.pill>
        <span style="color:var(--muted);font-size:12px">this is not an answer — the plane is fail-honest</span>
      </div>
      <pre
        class="ai-config-hint"
        id={"#{@id}-hint"}
        style="white-space:pre-wrap;margin:0;font-size:12px;background:var(--panel,#111);padding:12px;border-radius:8px;overflow:auto"
      >{Server.configuration_hint()}</pre>
    </div>
    """
  end

  def ai_result(%{result: {:error, :unauthorized}} = assigns) do
    ~H"""
    <div class="card ai-result ai-result-unauthorized" id={@id} data-state="unauthorized">
      <.pill variant="bad"><span id={"#{@id}-badge"}>Requires platform/operator authority</span></.pill>
      <p style="margin:8px 0 0;color:var(--muted);font-size:13px">
        Cross-tenant analytics runs on the token-blind aggregate plane and is authorized only for a
        platform/operator caller (deny-by-default). A tenant-plane session is refused before any row
        is read — no aggregate is fabricated.
      </p>
    </div>
    """
  end

  def ai_result(%{result: {:error, :pii_egress_refused}} = assigns) do
    ~H"""
    <div class="card ai-result ai-result-refused" id={@id} data-state="pii_egress_refused">
      <.pill variant="bad"><span id={"#{@id}-badge"}>Refused: PII egress blocked</span></.pill>
      <p style="margin:8px 0 0;color:var(--muted);font-size:13px">
        The masking chokepoint refused this payload (a vault token or unresolved field reached the
        egress boundary). Nothing was sent. INV-7 held.
      </p>
    </div>
    """
  end

  def ai_result(%{result: {:error, _reason}} = assigns) do
    ~H"""
    <div class="card ai-result ai-result-error" id={@id} data-state="error">
      <.pill variant="warn"><span id={"#{@id}-badge"}>Unavailable</span></.pill>
      <p style="margin:8px 0 0;color:var(--muted);font-size:13px">
        The AI plane could not complete this request. No result is shown (payload-free, EG6).
      </p>
    </div>
    """
  end

  def ai_result(%{result: nil} = assigns) do
    ~H"""
    <div id={@id}></div>
    """
  end
end
