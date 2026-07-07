defmodule DriftwoodWeb.ErrorHTML do
  @moduledoc "Minimal error renderer for the Driftwood endpoint (plain-text status)."

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
