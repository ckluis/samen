defmodule Samen.Web.Layouts do
  @moduledoc """
  The shared Samen root layout (WS-D D1.4, ADR-022).

  Driftwood and PawChart each hand-authored an identical minimal HTML shell for their
  root layout — the only difference was the `<title>` text. ADR-022 decided the generic
  root layout IS worth extracting (unlike the endpoint, which stays a thin emitted file),
  so the generator can emit a one-liner `layouts.ex` and "framework code is inherited,
  not re-emitted" holds for the layout too.

  ## Usage

  A host web app's layouts module becomes:

      defmodule MyAppWeb.Layouts do
        use Samen.Web.Layouts, title: "MyApp — my product"
      end

  and its router keeps referencing it as before:

      plug(:put_root_layout, html: {MyAppWeb.Layouts, :root})

  `:title` is optional — it defaults to the host module's top namespace with a trailing
  `Web` stripped (`DriftwoodWeb.Layouts` → `"Driftwood"`), so a bare
  `use Samen.Web.Layouts` is enough for the common case.

  The shell is intentionally minimal: viewport + CSRF meta, the shared Samen UI kit
  stylesheet served from the samen_web dependency's priv via the host endpoint's scoped
  `Plug.Static` (ADR-009), and `@inner_content`. No asset pipeline — a real deploy would
  add esbuild/tailwind in the host app, not here.
  """
  use Phoenix.Component

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Phoenix.Component

      @samen_layout_title Keyword.get(opts, :title) ||
                            Samen.Web.Layouts.default_title(__MODULE__)

      @doc "The root layout — delegates to the shared `Samen.Web.Layouts.root/1` shell."
      def root(assigns) do
        assigns = Phoenix.Component.assign(assigns, :samen_layout_title, @samen_layout_title)
        Samen.Web.Layouts.root(assigns)
      end
    end
  end

  @doc """
  Derives the default page title from a host layouts module:
  the top namespace segment with a trailing `Web` stripped
  (`DriftwoodWeb.Layouts` → `"Driftwood"`).
  """
  def default_title(module) do
    module
    |> Module.split()
    |> List.first()
    |> String.replace_suffix("Web", "")
  end

  @doc """
  The shared minimal HTML shell. Expects `@samen_layout_title` (set by the `__using__`
  wrapper) and `@inner_content`.
  """
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>{@samen_layout_title}</title>
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
