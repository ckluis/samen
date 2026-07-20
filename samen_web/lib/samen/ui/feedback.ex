defmodule Samen.UI.Feedback do
  @moduledoc """
  Feedback / status primitives of the `Samen.UI` kit: `empty_state/1`, `skeleton/1`,
  `progress/1`, `pill/1`, `metric/1`, and the `lifecycle_pill/1` (+ its
  `lifecycle_stages/0`). Split out of the `Samen.UI` god-module
  (behaviour-identical). `lifecycle_pill/1` composes `pill/1` as a SIBLING here; the
  `pill/1` primitive is also imported by `Samen.UI.Object` and `Samen.UI.Table`.
  `Samen.UI` re-exports each via `defdelegate`.
  """
  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # Empty state (ADR-016 §5 / WS-A design §3.1 — the G5 primitive)
  # ---------------------------------------------------------------------------

  @doc """
  The standard zero-rows empty state (ADR-016 §5, AC-G5-1 component half): an icon
  glyph, a `title`, an optional `body`, and two slots — `:actions` (the primary CTA,
  e.g. the "New …" button) and `:sample` (the optional "load sample data" affordance
  that A5's guarded `SampleData.load/2` will feed). `list_view/1` renders this as its
  default `:empty`, so every list that adopts the kit gets the consistent empty state
  at zero extra cost.

  Purely presentational — copy in, markup out. It renders no field values, so it has
  no masking surface.
  """
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :icon, :string, default: nil, doc: "a leading glyph (decorative, aria-hidden)"
  attr :class, :any, default: nil

  slot :actions, doc: "the primary call-to-action button(s)"
  slot :sample, doc: "the optional load-sample-data affordance (ADR-016 §5)"

  def empty_state(assigns) do
    assigns =
      assign(assigns, :class_attr, Enum.join(["card", "empty-state"] ++ List.wrap(assigns.class), " "))

    ~H"""
    <div
      class={@class_attr}
      style="padding:34px 24px;display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center"
    >
      <div :if={@icon} class="empty-icon" aria-hidden="true" style="font-size:26px;line-height:1">{@icon}</div>
      <h3 class="empty-title" style="margin:0;font-size:15px;font-weight:600">{@title}</h3>
      <p :if={@body} class="empty-body" style="margin:0;color:var(--muted);font-size:13px;max-width:44ch">{@body}</p>
      <div :if={@actions != []} class="empty-actions" style="display:flex;align-items:center;gap:8px;margin-top:8px">
        {render_slot(@actions)}
      </div>
      <div :if={@sample != []} class="empty-sample" style="margin-top:4px;font-size:12px;color:var(--muted)">
        {render_slot(@sample)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Skeleton (WS-E E6.2, ADR-030 — the loading-placeholder primitive)
  # ---------------------------------------------------------------------------

  @doc """
  A loading skeleton (WS-E E6.2): `rows` shimmer placeholder lines standing in for
  content that has not loaded yet. `avatar` prepends a round avatar placeholder per
  row (the list/table shape). Paired with the `samen-shimmer` keyframes in
  `samen_ui.css`; honours `prefers-reduced-motion`.

  PURELY PRESENTATIONAL — it renders NO data at all (abstract bars only), so it has
  no masking surface and cannot leak a value it never receives. This ships the
  primitive + wires it into `list_view/1`'s `loading` state; the fleet-wide
  `assign_async` conversion of every list is explicitly DEFERRED (design §6,
  decompose rule).
  """
  attr :rows, :integer, default: 5
  attr :avatar, :boolean, default: false
  attr :class, :any, default: nil

  def skeleton(assigns) do
    assigns =
      assigns
      |> assign(:count, max(assigns.rows, 1))
      |> assign(:class_attr, Enum.join(["skeleton" | List.wrap(assigns.class)], " "))

    ~H"""
    <div class={@class_attr} role="status" aria-busy="true" aria-live="polite">
      <span class="sr-only" style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)">Loading…</span>
      <div :for={_ <- 1..@count} class="skeleton-row" aria-hidden="true">
        <div :if={@avatar} class="skeleton-line avatar"></div>
        <div class="skeleton-line narrow"></div>
        <div class="skeleton-line"></div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Pill (status badge)
  # ---------------------------------------------------------------------------

  @doc """
  A status pill. `variant` selects the color scheme
  (`ok | warn | bad | info | mut`). The label is the default inner block — it
  renders WHATEVER value it is handed, including a `%Samen.Masked{}` (→ `••••`).
  The kit adds no unmasking here.
  """
  attr :variant, :string, default: "mut", values: ~w(ok warn bad info mut)
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={["pill", @variant]}>
      <span class="d"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Progress bar
  # ---------------------------------------------------------------------------

  @doc """
  A progress bar. `value` (0-100) sets the fill width; `label` is the right-aligned
  readout (a dollar amount, a health word, …). `color` is a CSS color for the fill
  (default the brand green). Renders `label` verbatim — a `%Masked{}` label shows
  `••••`.
  """
  attr :value, :integer, default: 0
  attr :label, :any, default: nil
  attr :color, :string, default: "var(--green)"

  def progress(assigns) do
    assigns = assign(assigns, :pct, clamp(assigns.value))

    ~H"""
    <div class="prog">
      <div class="track">
        <div class="fill" style={"width:#{@pct}%;background:#{@color}"}></div>
      </div>
      <span :if={@label != nil} class="pct">{@label}</span>
    </div>
    """
  end

  defp clamp(v) when is_integer(v), do: v |> max(0) |> min(100)
  defp clamp(_), do: 0

  # ---------------------------------------------------------------------------
  # Metric card
  # ---------------------------------------------------------------------------

  @doc """
  A metric card. `label` is the small key, `value` the large number. `delta` is an
  optional signed change; `delta_dir` (`up | down`) colors it. `sub` is optional
  sub-text under the value. `spark` is an optional list of 0-100 heights for the
  sparkline (the last bar is highlighted). An optional `:icon` slot leads the label.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :delta, :string, default: nil
  attr :delta_dir, :string, default: "up", values: ~w(up down)
  attr :sub, :string, default: nil
  attr :spark, :list, default: []
  slot :icon

  def metric(assigns) do
    ~H"""
    <div class="metric">
      <div class="k">
        <span :if={@icon != []} class="i">{render_slot(@icon)}</span>
        {@label}
      </div>
      <div class="v">
        <span class="num">{@value}</span>
        <span :if={@delta} class={["delta", @delta_dir]}>{@delta}</span>
      </div>
      <div :if={@sub} class="sub">{@sub}</div>
      <div :if={@spark != []} class="spark">
        <%= for {h, idx} <- Enum.with_index(@spark) do %>
          <i class={idx == length(@spark) - 1 && "hi"} style={"height:#{clamp(h)}%"}></i>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Lifecycle-stage pill (ADR-011 §8) — Tier-1 custom-field convention
  # ---------------------------------------------------------------------------

  @doc """
  A prospecting lifecycle-stage pill (ADR-011 §8). `stage` is the Tier-1
  `person.custom["lifecycle_stage"]` value (a string in the bounded set
  `lead → mql → sql → customer → churned`). A nil/unknown stage renders nothing —
  a contact without a stage shows no pill. Purely presentational; the bounded set is
  a framework convention a vertical can style via CSS.
  """
  attr :stage, :any, default: nil

  def lifecycle_pill(assigns) do
    ~H"""
    <.pill :if={lifecycle_known?(@stage)} variant={lifecycle_variant(@stage)}>{lifecycle_label(@stage)}</.pill>
    """
  end

  @doc "The bounded framework lifecycle stages (ADR-011 §8)."
  def lifecycle_stages, do: ~w(lead mql sql customer churned)

  defp lifecycle_known?(stage) when is_binary(stage), do: stage in lifecycle_stages()
  defp lifecycle_known?(_), do: false

  defp lifecycle_variant("lead"), do: "info"
  defp lifecycle_variant("mql"), do: "info"
  defp lifecycle_variant("sql"), do: "warn"
  defp lifecycle_variant("customer"), do: "ok"
  defp lifecycle_variant("churned"), do: "bad"
  defp lifecycle_variant(_), do: "mut"

  defp lifecycle_label("lead"), do: "Lead"
  defp lifecycle_label("mql"), do: "MQL"
  defp lifecycle_label("sql"), do: "SQL"
  defp lifecycle_label("customer"), do: "Customer"
  defp lifecycle_label("churned"), do: "Churned"
  defp lifecycle_label(other), do: to_string(other)
end
