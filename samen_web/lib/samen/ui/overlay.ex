defmodule Samen.UI.Overlay do
  @moduledoc """
  Overlay + search primitives of the `Samen.UI` kit: the accessible `modal/1`
  (ADR-016 §2), the `delete_confirm/1` interlock, the per-list `search_box/1`, and
  the ⌘K `command_palette/1` (ADR-027). Split out of the `Samen.UI` god-module
  (behaviour-identical). `modal/1` uses `<.focus_wrap>` from `use Phoenix.Component`;
  `command_palette/1` renders result rows via the `Samen.UI` facade helpers
  (`humanize_resource/1` / `palette_label/1`), which remain resolvable through
  `defdelegate`. `Samen.UI` re-exports each via `defdelegate`.
  """
  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # Search — ⌘K command palette + per-list search box (WS-E E4.3; ADR-027)
  # ---------------------------------------------------------------------------

  @doc """
  The per-list SEARCH BOX that fills the sidebar `:search` slot (ADR-027 decision 4;
  the placeholder the design flagged as fed by nothing). A tiny GET form that carries
  the term (and current org) to the ⌘K search page — the same `Samen.Search` engine,
  scoped to the mount. Purely a navigation affordance: no value is rendered here, so
  there is no masking surface.

    * `action`  — the search page path (default `/search`).
    * `org_id`  — carried through so the target page resolves the same current org.
    * `placeholder` — input copy.

  The input carries `data-cmdk` so the framework-global ⌘K shortcut (an inline
  script in the shared root layout, WS-E E6 / ADR-027 carry) can focus it from
  anywhere on a list page. It renders the leading magnifier glyph + a `⌘K` kbd
  hint, so it is a visual drop-in for the old static `.search` placeholder. No
  value is rendered here (it is a navigation affordance) — no masking surface.
  """
  attr :action, :string, default: "/search"
  attr :org_id, :string, default: nil
  attr :placeholder, :string, default: "Search…"

  def search_box(assigns) do
    ~H"""
    <form class="search" method="get" action={@action} role="search">
      <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
      </svg>
      <input
        type="search"
        name="q"
        class="search-input"
        placeholder={@placeholder}
        autocomplete="off"
        aria-label="Search"
        data-cmdk
      />
      <span class="kbd">⌘K</span>
      <input :if={@org_id} type="hidden" name="org" value={@org_id} />
    </form>
    """
  end

  @doc """
  The ⌘K COMMAND PALETTE (ADR-027 decision 4) — a single framework panel that renders
  the ranked, org-scoped, per-plane-masked `%Samen.Search.Result{}`s from
  `Samen.Search.query/3`. Every vertical mounts it via `samen_search_routes` at ≈0 LOC;
  zero authored search LiveViews.

  ## Masking posture (masking watch-list)

  This component renders ONLY `result.display` — the bounded NON-PII allowlist the
  engine already projected through the PII resolver. It never touches `result.record`'s
  vaulted fields, never reveals a vaulted value, and never unwraps a masked value. The
  masking guarantee lives at the query seam (the engine); this surface cannot
  re-introduce a leak because it is handed only masked-safe display values.

    * `id`          — DOM id (default `"cmdk"`).
    * `q`           — the current term (echoed into the input).
    * `results`     — a list of `%Samen.Search.Result{}`.
    * `event`       — the LiveView event the debounced input fires (default `"search"`).
    * `placeholder` — input copy.
  """
  attr :id, :string, default: "cmdk"
  attr :q, :string, default: ""
  attr :results, :list, default: []
  attr :event, :string, default: "search"
  attr :placeholder, :string, default: "Search everything…"

  def command_palette(assigns) do
    ~H"""
    <div class="cmdk" id={@id}>
      <form class="cmdk-form" phx-change={@event} phx-submit={@event} role="search">
        <input
          id={"#{@id}-input"}
          type="search"
          name="q"
          class="cmdk-input"
          value={@q}
          placeholder={@placeholder}
          autocomplete="off"
          autofocus
          phx-debounce="150"
          aria-label="Search everything"
        />
      </form>

      <ul class="cmdk-results" role="listbox">
        <li :for={r <- @results} class="cmdk-hit" role="option">
          <span class="cmdk-kind">{Samen.UI.humanize_resource(r.resource_name)}</span>
          <span class="cmdk-label">{Samen.UI.palette_label(r.display)}</span>
        </li>
        <li :if={@q not in [nil, ""] and @results == []} class="cmdk-empty">No matches.</li>
      </ul>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Modal (ADR-016 §2 — role=dialog, focus trap, escape/click-away close)
  # ---------------------------------------------------------------------------

  @doc """
  An accessible modal / slide-over container (ADR-016 §2, AC-G1-9): `role="dialog"` +
  `aria-modal` + `aria-labelledby` (wired to the `title`), a FOCUS TRAP via
  `Phoenix.Component.focus_wrap/1`, and close on Escape (`phx-window-keydown` +
  `phx-key="escape"`), click-away (`phx-click-away`), or the ✕ button — each firing
  `on_cancel` (an event name string or `Phoenix.LiveView.JS`; the hosting LiveView
  owns it). Hosts create/edit `simple_form/1`s without a full-page nav.

  Render it conditionally from the LiveView (`<.modal :if={@show_modal} …>`); the
  content is the default inner block. Purely presentational — it renders no field
  values itself, so masking rides on what the caller puts inside (a `form_field/1`
  keeps its own masked branch).
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :on_cancel, :any, default: nil, doc: "event name (string) or JS command fired by escape/click-away/✕"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal-overlay"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
      style="position:fixed;inset:0;z-index:60;display:flex;align-items:center;justify-content:center;background:rgba(15,16,24,.45);padding:20px"
    >
      <.focus_wrap
        id={"#{@id}-content"}
        class="card modal-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title && "#{@id}-title"}
        phx-click-away={@on_cancel}
        style="background:#fff;min-width:340px;max-width:560px;width:100%;max-height:calc(100vh - 40px);overflow:auto;padding:18px 20px"
      >
        <div class="modal-head" style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px">
          <h2 :if={@title} id={"#{@id}-title"} class="modal-title" style="margin:0;font-size:15px;font-weight:650">{@title}</h2>
          <button
            type="button"
            class="modal-close"
            phx-click={@on_cancel}
            aria-label="Close"
            style="background:none;border:0;cursor:pointer;font-size:14px;color:var(--muted);margin-left:auto"
          >
            ✕
          </button>
        </div>
        {render_slot(@inner_block)}
      </.focus_wrap>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Delete-confirm affordance (ADR-016 §2 — destructive actions are interlocked)
  # ---------------------------------------------------------------------------

  @doc """
  The delete-confirm affordance: a danger-styled button carrying LiveView's built-in
  `data-confirm` interlock — the client MUST confirm before the `phx-click` event
  (pass `phx-click`/`phx-value-id`/`phx-target` via `:rest`) reaches the server, so a
  destructive action is never one accidental click away. The label defaults to
  "Delete" (override via the inner block).

  Keep `message` to static framework copy — don't interpolate field values into it
  (a `%Masked{}` does not belong in an HTML attribute).
  """
  attr :message, :string, default: "Delete this record? This cannot be undone."
  attr :label, :string, default: "Delete"
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block

  def delete_confirm(assigns) do
    ~H"""
    <button
      type="button"
      class="btn danger"
      data-confirm={@message}
      style="color:var(--bad, #b91c1c);border-color:var(--bad, #b91c1c)"
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@label}
      <% end %>
    </button>
    """
  end
end
