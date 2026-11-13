defmodule Samen.UI.State do
  @moduledoc """
  The unhappy-path layer of the `Samen.UI` kit (audit F04/F07): the shared
  loading / error vocabulary every data component forwards to, plus the notice
  primitives (`flash_group/1`, `connection_banner/1`).

    * `error_state/1`      — the error sibling of `empty_state/1` (same visual family), with an
      optional retry event.
    * `state_view/2`       — plain helper (NOT a component): given a data component's assigns
      (`loading`, `error`, `retry_event`) it renders the matching `skeleton/1` or
      `error_state/1`. Every data component calls `gated?/1` first and, when true, renders this
      instead of its body, so the components do not each re-implement it.
    * `flash_group/1`      — renders `info`/`success`/`warning`/`error` flashes (role=status /
      role=alert), dismissible with JS off (a CSS checkbox) and cleared server-side by
      LiveView's built-in `lv:clear-flash` when JS is on.
    * `connection_banner/1`— the "reconnecting" banner driven by LiveView's
      `phx-disconnected` / `phx-connected` bindings.

  ## Masking posture

  Purely presentational: it renders the strings it is handed (a flash message, an error
  message) and nothing else. An `error` that is not a binary renders a generic message — a
  term is never `inspect`-ed into the page, so a struct that carries a `%Samen.Masked{}` or a
  vault token cannot reach the DOM through this module.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import Samen.UI.Feedback, only: [skeleton: 1]

  @doc "True when a data component's assigns ask for the loading or error state."
  def gated?(assigns), do: loading?(assigns) or error?(Map.get(assigns, :error))

  defp loading?(assigns), do: Map.get(assigns, :loading) == true

  @doc false
  def error?(nil), do: false
  def error?(false), do: false
  def error?(_), do: true

  @doc false
  # A binary error is shown as the body; anything else gets the generic copy (never inspected).
  def error_body(msg) when is_binary(msg) and msg != "", do: msg
  def error_body(_), do: nil

  @doc """
  Render the loading or error state for a data component's `assigns` (error wins over loading).
  `shape` picks the skeleton silhouette (`"rows"`, `"card"`, `"chart"`).
  """
  def state_view(assigns, shape \\ "rows") do
    assigns =
      assigns
      |> assign(:state_shape, shape)
      |> assign(:state_error, Map.get(assigns, :error))
      |> assign(:state_retry, Map.get(assigns, :retry_event))

    ~H"""
    <%= if error?(@state_error) do %>
      <.error_state body={error_body(@state_error)} retry_event={@state_retry} />
    <% else %>
      <div class="card state-loading">
        <.skeleton rows={3} shape={@state_shape} />
      </div>
    <% end %>
    """
  end

  @doc """
  The error state: the failure sibling of `empty_state/1` (same `.card` family). `body` is the
  optional detail; `retry_event` adds a "Try again" button that fires that LiveView event.
  """
  attr :title, :string, default: "Something went wrong"
  attr :body, :string, default: nil
  attr :retry_event, :string, default: nil
  attr :retry_label, :string, default: "Try again"
  attr :class, :any, default: nil

  def error_state(assigns) do
    assigns =
      assign(assigns, :class_attr, Enum.join(["card", "error-state"] ++ List.wrap(assigns.class), " "))

    ~H"""
    <div class={@class_attr} role="alert">
      <div class="error-icon" aria-hidden="true">!</div>
      <h3 class="error-title">{@title}</h3>
      <p :if={@body} class="error-body">{@body}</p>
      <div :if={@retry_event} class="error-actions">
        <button type="button" class="btn" phx-click={@retry_event} phx-disable-with="Retrying…">
          {@retry_label}
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Flash + connection state (F07)
  # ---------------------------------------------------------------------------

  # The flash kinds the kit renders. Any other key (e.g. a hand-over secret such as
  # `:totp_recovery_codes`) is deliberately NOT displayed here.
  @kinds ~w(info success warning error)

  @doc """
  Renders the flash messages of `flash` (a `%{"info" => msg}` map, as `@flash` is in a LiveView
  layout and `conn.assigns.flash` is in a controller layout). Only `info`, `success`, `warning`
  and `error` are shown; `error` is `role="alert"`, the rest `role="status"`. Each is dismissible:
  with JS off a CSS-only checkbox hides it; under LiveView the ✕ also pushes `lv:clear-flash`.
  """
  attr :flash, :map, default: %{}
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    assigns = assign(assigns, :entries, flash_entries(assigns.flash))

    ~H"""
    <div :if={@entries != []} id={@id} class="flash-group">
      <div
        :for={{kind, msg} <- @entries}
        class={"flash flash-#{kind}"}
        role={if kind == "error", do: "alert", else: "status"}
        id={"#{@id}-#{kind}"}
      >
        <input type="checkbox" id={"#{@id}-#{kind}-x"} class="flash-x" aria-hidden="true" tabindex="-1" />
        <span class="flash-msg">{msg}</span>
        <label
          for={"#{@id}-#{kind}-x"}
          class="flash-close"
          role="button"
          tabindex="0"
          aria-label="Dismiss"
          phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
        >
          ✕
        </label>
      </div>
    </div>
    """
  end

  @doc false
  # `[{kind, message}]` for the renderable kinds present with a non-blank binary message.
  def flash_entries(flash) when is_map(flash) do
    for kind <- @kinds,
        msg = Map.get(flash, kind) || Map.get(flash, String.to_atom(kind)),
        is_binary(msg) and String.trim(msg) != "",
        do: {kind, msg}
  end

  def flash_entries(_), do: []

  @doc """
  The connection-state banner. Server-rendered hidden; LiveView's `phx-disconnected` shows it
  and `phx-connected` hides it, so a dropped socket no longer looks like a frozen page. Place it
  once inside a LiveView layout. (The `.phx-error` classes LiveView puts on the container are
  styled in `samen_ui.css` too.)
  """
  attr :id, :string, default: "connection-banner"

  def connection_banner(assigns) do
    ~H"""
    <div
      id={@id}
      class="conn-banner"
      role="status"
      aria-live="polite"
      hidden
      phx-disconnected={JS.show(to: "##{@id}")}
      phx-connected={JS.hide(to: "##{@id}")}
    >
      Connection lost — reconnecting…
    </div>
    """
  end
end
