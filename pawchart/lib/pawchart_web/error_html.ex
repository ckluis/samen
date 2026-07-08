defmodule PawChartWeb.ErrorHTML do
  @moduledoc "Minimal error renderer for PawChart."
  use Phoenix.Component

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
