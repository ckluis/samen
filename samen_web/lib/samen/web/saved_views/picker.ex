defmodule Samen.Web.SavedViews.Picker do
  @moduledoc """
  The server-rendered SAVED-VIEWS picker (G10, T58) — the framework UI for listing a user's
  saved views and applying one, with a no-JS floor.

  The LIST and APPLY are the no-JS floor: each saved view renders as a REAL `<a href>`
  (built by the caller's `:apply_href` function, conventionally `?view=<id>`), so a
  JS-off client selects a saved view by ordinary GET and the owning LiveView restores it in
  `handle_params/3`. SAVE and DELETE are progressive enhancements layered on top
  (`phx-submit` / `phx-click`) — present only when the caller wires the events.

  Masking is not this component's concern: it renders only the saved view's NAME
  (operator-authored, non-PII) — never a domain field value. The restored VIEW (the actual
  records) renders through the normal masked WS-G components.
  """
  use Phoenix.Component

  @doc """
  Render the saved-views picker.

    * `:views` (required) — the list of `Views.SavedView` rows (`Samen.Web.SavedViews.list/4`).
    * `:apply_href` (required) — a 1-arity fun `(saved_view) -> url` building the real apply
      link (the no-JS floor, conventionally `?view=<id>`).
    * `:active_id` — the id of the currently applied saved view (marked `aria-current`).
    * `:id` — the container DOM id (default `"saved-views"`).
    * `:label` — the picker heading (default `"Saved views"`).
    * `:save_event` — when set, renders a `phx-submit` name form (a JS enhancement).
    * `:delete_event` — when set, renders a per-view `phx-click` delete control (JS enhancement).
    * `:surface` / `:view_type` — carried as hidden fields on the save form.
  """
  attr :id, :string, default: "saved-views"
  attr :label, :string, default: "Saved views"
  attr :views, :list, required: true
  attr :apply_href, :any, required: true, doc: "1-arity fun (saved_view) -> url"
  attr :active_id, :string, default: nil
  attr :save_event, :string, default: nil
  attr :delete_event, :string, default: nil
  attr :surface, :string, default: nil
  attr :view_type, :any, default: nil

  def saved_views(assigns) do
    ~H"""
    <nav id={@id} class="samen-saved-views" aria-label={@label}>
      <h3 class="samen-saved-views__label">{@label}</h3>

      <ul :if={@views != []} class="samen-saved-views__list">
        <li :for={sv <- @views} class="samen-saved-views__item">
          <a
            href={@apply_href.(sv)}
            class="samen-saved-views__link"
            aria-current={if to_string(sv.id) == to_string(@active_id), do: "true"}
          >
            {sv.name}
          </a>
          <button
            :if={@delete_event}
            type="button"
            class="samen-saved-views__delete"
            phx-click={@delete_event}
            phx-value-id={sv.id}
            aria-label={"Delete saved view #{sv.name}"}
          >
            &times;
          </button>
        </li>
      </ul>

      <p :if={@views == []} class="samen-saved-views__empty">No saved views yet.</p>

      <form :if={@save_event} class="samen-saved-views__save" phx-submit={@save_event}>
        <input type="hidden" name="surface" value={@surface} />
        <input type="hidden" name="view_type" value={view_type_value(@view_type)} />
        <input
          type="text"
          name="name"
          class="samen-saved-views__name"
          placeholder="Name this view"
          required
        />
        <button type="submit" class="samen-saved-views__submit">Save current view</button>
      </form>
    </nav>
    """
  end

  defp view_type_value(vt) when is_atom(vt) and not is_nil(vt), do: Atom.to_string(vt)
  defp view_type_value(vt) when is_binary(vt), do: vt
  defp view_type_value(_), do: "table"
end
