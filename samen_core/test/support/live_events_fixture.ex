defmodule SamenCore.Support.LiveEventsFixture do
  @moduledoc """
  ADR-052 §2.1 / R2 fixture: a LiveView-SHAPED module (samen_core has no Phoenix) whose
  `handle_event/3` clauses exercise every head shape `Samen.Observability.LiveEvents` reads
  from the compiled debug info: a plain literal, a `literal = var` match, a binary-prefix
  pattern, a PII-shaped literal, and a catch-all.
  """

  def handle_event("save", _params, socket), do: {:noreply, socket}
  def handle_event("sort" = _event, _params, socket), do: {:noreply, socket}
  def handle_event("row:" <> _id, _params, socket), do: {:noreply, socket}
  def handle_event("alice@example.com", _params, socket), do: {:noreply, socket}
  def handle_event(_event, _params, socket), do: {:noreply, socket}
end

defmodule SamenCore.Support.LiveEventsDeclared do
  @moduledoc """
  ADR-052 §2.1 fixture: a module that DECLARES its events (`__samen_live_events__/0`) — the
  path for releases built without debug info. Its `handle_event/3` is a catch-all, so the
  declaration is the only source.
  """

  def __samen_live_events__, do: ["approve", "Not A Label"]

  def handle_event(_event, _params, socket), do: {:noreply, socket}
end
