defmodule PawChartWeb.Layouts do
  @moduledoc """
  The PawChart root layout. A minimal HTML shell wrapping the LiveView planes — enough
  to serve real pages over HTTP for the dogfood evidence. Mirrors Driftwood's pattern.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>PawChart — vet clinic SaaS on Samen</title>
        <%!-- ADR-009: the shared Samen UI kit stylesheet from the samen_web dep's priv. --%>
        <link rel="stylesheet" href="/assets/samen_ui.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
