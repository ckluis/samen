defmodule DriftwoodWeb.Layouts do
  @moduledoc """
  The Driftwood root layout (T5.3). A minimal HTML shell wrapping the LiveView planes —
  enough to serve real pages over HTTP for the boot/curl dogfood evidence. No asset
  pipeline (this is a local dogfood; a real deploy would add esbuild/tailwind).
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
        <title>Driftwood</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
