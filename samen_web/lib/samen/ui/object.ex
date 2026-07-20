defmodule Samen.UI.Object do
  @moduledoc """
  Object / activity primitives of the `Samen.UI` kit: the crown-jewel
  `object_card/1` (ADR-012 §4.4), the `timeline/1` (ADR-011 §6.2), and the
  `mask_bar/1` / `token_blind_bar/1` banners. Split out of the `Samen.UI`
  god-module (behaviour-identical). `object_card/1` and `timeline/1` compose
  `pill/1` from `Samen.UI.Feedback` (imported below). `Samen.UI` re-exports each via
  `defdelegate`.
  """
  use Phoenix.Component

  import Samen.UI.Feedback, only: [pill: 1]

  # ---------------------------------------------------------------------------
  # Object-unfurl card (ADR-012 §4.4 — the crown jewel's renderer)
  # ---------------------------------------------------------------------------

  @doc """
  The **object-unfurl card** — renders a `%Samen.Web.ObjectRef.Card{}` produced by
  `Samen.Web.ObjectRef.resolve/3` (ADR-012 §4). Given a resolved card (or a resolver
  `{:error, reason}`), it renders a compact live preview of a catalogued object.

  ## Masking BY CONSTRUCTION (the crown-jewel invariant)

  Every value on the card is the resolver's ALREADY-RESOLVED field — a plaintext string on the
  tenant plane, a `%Masked{}` on the operator plane. This component renders each value
  verbatim via `{...}`, so a `%Masked{}` renders `••••` through `Phoenix.HTML.Safe` (the
  `Samen.Masked` impl). It has NO unmasking branch, never reveals through the kernel vault, and
  never pulls a mask apart to read its inner value. The SAME card, resolved for two viewers,
  therefore renders CLEAR for the owning tenant and `••••` for the operator with zero
  per-viewer code here.

  ## Error / not-available state (no leak)

  Passed `{:error, :not_found}` / `:unknown_key` / `:forbidden`, it renders an INERT
  "not available" chip — the same rendering for a nonexistent id and a cross-org id (no
  existence oracle, no PII). A resolver failure NEVER downgrades to plaintext.
  """
  attr :card, :any, required: true, doc: "a %Samen.Web.ObjectRef.Card{} or {:error, reason}"

  def object_card(%{card: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <span class="obj-card obj-card-na" data-obj-error={to_string(@reason)}>
      <span class="obj-na-icon">∅</span>
      <span class="obj-na-text">Object not available</span>
    </span>
    """
  end

  def object_card(%{card: %Samen.Web.ObjectRef.Card{}} = assigns) do
    ~H"""
    <span class="obj-card" data-obj-key={@card.key} data-obj-id={@card.id}>
      <span class="obj-card-avatar">{@card.icon || "•"}</span>
      <span class="obj-card-body">
        <span class="obj-card-kicker">{@card.subtitle || @card.key}</span>
        <span class="obj-card-title">
          <%= if @card.href do %>
            <a href={@card.href} class="obj-card-link">{@card.title}</a>
          <% else %>
            {@card.title}
          <% end %>
        </span>
        <span :if={@card.badges != []} class="obj-card-badges">
          <.pill :for={{variant, label} <- @card.badges} variant={pill_variant(variant)}>{label}</.pill>
        </span>
        <span :if={@card.fields != []} class="obj-card-fields">
          <span :for={{label, value} <- @card.fields} class="obj-card-field">
            <span class="obj-card-field-label">{label}</span>
            <span class="obj-card-field-value">{value}</span>
          </span>
        </span>
      </span>
    </span>
    """
  end

  def object_card(assigns) do
    ~H"""
    <span class="obj-card obj-card-na"><span class="obj-na-text">Object not available</span></span>
    """
  end

  # Card badge variants may arrive as atoms (from DefaultCard) or strings (from override
  # cards). Normalize to the `.pill` variant vocabulary; anything unknown → "mut".
  defp pill_variant(v) when v in ["ok", "warn", "bad", "info", "mut"], do: v
  defp pill_variant(v) when is_atom(v), do: pill_variant(Atom.to_string(v))
  defp pill_variant(_), do: "mut"

  # ---------------------------------------------------------------------------
  # Banner: masked impersonation (mask-bar)
  # ---------------------------------------------------------------------------

  @doc """
  The masked-impersonation banner. The default inner block is the explanatory copy
  (use `<b>` for emphasis); `chip` is the right-aligned monospace status
  (e.g. session TTL + reason). Renders content verbatim.
  """
  attr :chip, :string, default: nil
  slot :inner_block, required: true

  def mask_bar(assigns) do
    ~H"""
    <div class="mask-bar">
      <div class="ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">
          <rect x="4" y="10" width="16" height="10" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" />
        </svg>
      </div>
      <div class="tx">{render_slot(@inner_block)}</div>
      <div :if={@chip} class="chip">{@chip}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Banner: token-blind aggregate (tb-bar)
  # ---------------------------------------------------------------------------

  @doc """
  The token-blind aggregate banner. The default inner block is the copy; `chip` is
  the right-aligned monospace privacy summary (e.g. `no reveal path · k ≥ 5`).
  """
  attr :chip, :string, default: nil
  slot :inner_block, required: true

  def token_blind_bar(assigns) do
    ~H"""
    <div class="tb-bar">
      <div class="ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">
          <path d="M4 19V9m6 10V5m6 14v-7" />
        </svg>
      </div>
      <div class="tx">{render_slot(@inner_block)}</div>
      <div :if={@chip} class="chip">{@chip}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Activity timeline (ADR-011 §6.2) — pure presentational, host-agnostic
  # ---------------------------------------------------------------------------

  @doc """
  The activity timeline (ADR-011 §6.2). A vertical rail of typed activity entries —
  each entry a per-type glyph (call · email · meeting · note · task), a `subject`
  title, a `status` pill, a `who / when` line, and the `body` as wrapped text.

  PURELY PRESENTATIONAL: it takes ALREADY-RESOLVED data (a list of plain maps) and
  renders it. It NEVER reads a resource, NEVER touches the vault, and NEVER knows
  about writes — the optional `:composer` slot lets a detail page drop a
  log-activity form ABOVE the rail without the component knowing anything about the
  write path. This makes it trivially unit-testable and inherited by every vertical
  (a future account timeline can reuse it verbatim).

  `entries` is a list of maps: `%{type, subject, body, status, at, who}` — `type` and
  `status` are the bounded activity enums (atoms), `at` a `DateTime | nil`, `subject`
  / `body` / `who` strings. A `%Samen.Masked{}` in any slot renders `••••` verbatim.
  """
  attr :entries, :list, required: true
  attr :empty, :string, default: "No activity yet."
  slot :composer

  def timeline(assigns) do
    ~H"""
    <div class="tl">
      <div :if={@composer != []} class="tl-composer">
        {render_slot(@composer)}
      </div>

      <div :if={@entries == []} class="tl-empty" style="padding:22px 20px;color:var(--muted)">
        {@empty}
      </div>

      <div :if={@entries != []} class="tl-rail">
        <div :for={e <- @entries} class="tl-entry" id={timeline_entry_id(e)}>
          <div class={"tl-glyph tl-#{timeline_type(e)}"} style="width:30px;height:30px;border-radius:50%;display:flex;align-items:center;justify-content:center;flex-shrink:0">
            {timeline_glyph(timeline_type(e))}
          </div>
          <div class="tl-body" style="flex:1;min-width:0">
            <div class="tl-head" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:4px">
              <span class="tl-type" style="font-size:11px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em">{timeline_type_label(timeline_type(e))}</span>
              <span class="tl-subject" style="font-weight:600;font-size:13px;color:#2a2b35">{Map.get(e, :subject) || "—"}</span>
              <.pill variant={timeline_status_variant(Map.get(e, :status))}>{timeline_status_label(Map.get(e, :status))}</.pill>
            </div>
            <div :if={timeline_present?(Map.get(e, :body))} class="tl-text" style="font-size:13px;color:#3a3b45;line-height:1.55;white-space:pre-wrap;word-break:break-word;margin:2px 0 6px">
              {Map.get(e, :body)}
            </div>
            <div class="tl-meta" style="font-size:11px;color:var(--muted)">
              <span :if={timeline_present?(Map.get(e, :who))}>{Map.get(e, :who)} · </span>{timeline_dt(Map.get(e, :at))}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Timeline helpers (bounded enums; presentational only) ---------------------

  defp timeline_entry_id(%{id: id}) when not is_nil(id), do: "tl-entry-#{id}"
  defp timeline_entry_id(_), do: "tl-entry"

  defp timeline_type(%{type: type}), do: type
  defp timeline_type(_), do: :note

  defp timeline_type_label(:call), do: "Call"
  defp timeline_type_label(:email), do: "Email"
  defp timeline_type_label(:meeting), do: "Meeting"
  defp timeline_type_label(:note), do: "Note"
  defp timeline_type_label(:task), do: "Task"
  defp timeline_type_label(other), do: to_string(other || "note")

  # Inline SVG glyphs matching the kit's stroke style (1.8 stroke, currentColor).
  defp timeline_glyph(:call) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6 19.8 19.8 0 0 1-3.1-8.7A2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2Z"/></svg>)
    )
  end

  defp timeline_glyph(:email) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></svg>)
    )
  end

  defp timeline_glyph(:meeting) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/></svg>)
    )
  end

  defp timeline_glyph(:note) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 3h11l5 5v13H4z"/><path d="M9 12h7M9 16h5M9 8h3"/></svg>)
    )
  end

  defp timeline_glyph(:task) do
    Phoenix.HTML.raw(
      ~s(<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M20 6 9 17l-5-5"/></svg>)
    )
  end

  defp timeline_glyph(_), do: timeline_glyph(:note)

  defp timeline_status_variant(:completed), do: "ok"
  defp timeline_status_variant(:pending), do: "warn"
  defp timeline_status_variant(:cancelled), do: "mut"
  defp timeline_status_variant(_), do: "mut"

  defp timeline_status_label(:completed), do: "completed"
  defp timeline_status_label(:pending), do: "pending"
  defp timeline_status_label(:cancelled), do: "cancelled"
  defp timeline_status_label(nil), do: "logged"
  defp timeline_status_label(other), do: to_string(other)

  defp timeline_present?(%Samen.Masked{}), do: true
  defp timeline_present?(v) when is_binary(v), do: String.trim(v) != ""
  defp timeline_present?(_), do: false

  defp timeline_dt(%DateTime{} = dt),
    do: "#{dt.year}-#{tl_pad(dt.month)}-#{tl_pad(dt.day)} #{tl_pad(dt.hour)}:#{tl_pad(dt.minute)} UTC"

  defp timeline_dt(_), do: "—"

  defp tl_pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
