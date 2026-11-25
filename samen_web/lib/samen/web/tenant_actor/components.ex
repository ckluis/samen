defmodule Samen.Web.TenantActor.Components do
  @moduledoc """
  The ONE denied / unavailable state a converted tenant LiveView renders when `Samen.Web.TenantActor` refused
  to name who is acting (`actor_state` is `:denied` or `:unavailable`; see `TenantActor.assign_actor/2`).

      <.actor_refused state={@actor_state} title="Contacts" nothing="there are no contacts to show" />

  `:denied` is the honest "no active membership" card (`id="actor-denied"`); `:unavailable` is the error state
  (`id="actor-unavailable"`): the lookup failed, nothing is shown rather than a wrong list. Neither carries data.

  Both carry a "Check again" button (`phx-click="retry_actor"`). The event is answered by the guard
  `TenantActor.assign_actor/2` attached (`TenantActor.recheck_event/3`), not by the view: it resolves who acts again and,
  when the person acts, patches the page to its own URL so it loads fresh. (A view's own `retry_load` is blocked while the
  page is refused, which is why this button is not that event.)
  """
  use Phoenix.Component
  import Samen.UI, only: [button: 1]

  attr :state, :atom, required: true, values: [:denied, :unavailable]
  attr :title, :string, required: true, doc: "the plural noun the unavailable heading names (\"Contacts\")"
  attr :nothing, :string, required: true, doc: "what the denied copy says is absent (\"there are no contacts to show\")"

  def actor_refused(%{state: :denied} = assigns) do
    ~H"""
    <div class="wrap">
      <div id="actor-denied" class="gtitle">
        <h3>No access</h3>
        <span class="lane">Your account holds no active membership in this workspace, so {@nothing}.</span>
        <.button type="button" phx-click="retry_actor" id="actor-retry">Check again</.button>
      </div>
    </div>
    """
  end

  def actor_refused(%{state: :unavailable} = assigns) do
    ~H"""
    <div class="wrap">
      <div id="actor-unavailable" class="gtitle">
        <h3>{@title} unavailable</h3>
        <span class="lane">We couldn't check who you are in this workspace. Nothing is shown rather than a wrong list.</span>
        <.button type="button" phx-click="retry_actor" id="actor-retry">Try again</.button>
      </div>
    </div>
    """
  end
end
