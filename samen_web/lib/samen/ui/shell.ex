defmodule Samen.UI.Shell do
  @moduledoc """
  App-shell primitives of the `Samen.UI` kit: the two-pane `app_shell/1` and the
  base `button/1`. Split out of the `Samen.UI` god-module (behaviour-identical);
  `Samen.UI` re-exports both via `defdelegate`, so `import Samen.UI; <.button>`
  keeps working unchanged.
  """
  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # App shell
  # ---------------------------------------------------------------------------

  @doc """
  The two-pane app shell: a `:sidebar` slot on the left, the default inner block
  (the `<main>`) on the right. Mirrors `.app > .side + .main` from the mockups.

  ## Responsive drawer (WS-E E6.1, ADR-030 — CSS-only affordance)

  The shell carries a hidden checkbox (`#samen-nav-toggle`) plus a hamburger
  `<label>` and a scrim `<label>`. On desktop both labels are `display:none` and
  the checkbox does nothing — the 252px grid is unchanged. At the mobile
  breakpoint the sidebar becomes an off-canvas drawer that the hamburger opens
  and the scrim closes, driven ENTIRELY by CSS `:checked ~` sibling rules (no JS
  framework, no hook). The checkbox/labels are out-of-flow (fixed / display:none),
  so the grid still sees exactly `.side` + `.main` as its two items. Purely
  layout — it renders no field values, so it has no masking surface.
  """
  slot :sidebar, required: true
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app">
      <input type="checkbox" id="samen-nav-toggle" class="nav-toggle-cb" aria-hidden="true" tabindex="-1" />
      <label for="samen-nav-toggle" class="nav-hamburger" aria-label="Toggle navigation menu">
        <svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M4 6h16M4 12h16M4 18h16" />
        </svg>
      </label>
      {render_slot(@sidebar)}
      <label for="samen-nav-toggle" class="nav-scrim" aria-hidden="true"></label>
      <main class="main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Button
  # ---------------------------------------------------------------------------

  @doc """
  A `.btn`. `variant="primary"` renders the dark filled button. Provide an optional
  `:icon` slot; the label is the default inner block. Extra attrs (`phx-click`,
  `type`, `disabled`, `class`, …) pass through via `:rest`.
  """
  attr :variant, :string, default: "default", values: ~w(default primary)
  attr :rest, :global, include: ~w(type disabled name value form phx-click phx-value-id)
  slot :icon
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class={if @variant == "primary", do: "btn primary", else: "btn"} {@rest}>
      <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
      {render_slot(@inner_block)}
    </button>
    """
  end
end
