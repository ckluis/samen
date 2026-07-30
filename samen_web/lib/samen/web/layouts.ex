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
  `Plug.Static` (ADR-009), the three Phoenix LiveView client `<script>` tags (ADR-042 C1),
  and `@inner_content`.

  ## Client runtime (ADR-042)

  This layout wires the Phoenix LiveView JS client for EVERY host at zero authored LOC
  per host — the same framework-first inheritance as `samen_ui.css`. There is still no
  node/esbuild/tailwind toolchain: the client is three vendored static files served via
  the host endpoint's scoped `Plug.Static` — `phoenix.min.js` + `phoenix_live_view.min.js`
  (from the deps' own `priv/static`, so client/server versions cannot skew) and a
  ~30-line hand-authored `app.js` (samen_web's priv), which connects the LiveSocket and
  carries the relocated ⌘K listener. Masking is unaffected: `app.js` is a transport shim
  that resolves no value (ADR-042 §6 / C6). See `docs/adr/ADR-042-liveview-client-adoption.md`.
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
        <%!--
          ADR-042 C1 — the Phoenix LiveView JS client: three vendored static bundles,
          served from the deps' + samen_web's priv via the host endpoint's scoped
          `Plug.Static` (ADR-042 §3). `defer` so they execute in DOM order after parse;
          each rides the existing `csp_nonce` seam (C7 — dormant-but-ready, as no host
          emits a CSP header today). `app.js` (C2) connects the LiveSocket and carries
          the relocated ⌘K listener; it is a transport shim that resolves no value, so
          masking stays server-rendered (C6 / §6). Inherited by every host at ≈0 LOC.
        --%>
        <script defer nonce={assigns[:csp_nonce]} src="/assets/phoenix.min.js"></script>
        <script defer nonce={assigns[:csp_nonce]} src="/assets/phoenix_live_view.min.js"></script>
        <script defer nonce={assigns[:csp_nonce]} src="/assets/app.js"></script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
