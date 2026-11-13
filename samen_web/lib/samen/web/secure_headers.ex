defmodule Samen.Web.SecureHeaders do
  @moduledoc """
  The framework's browser security headers (ARCH-11) — a plug for the host `:browser`
  pipeline, emitted into every generated router and mounted by driftwood and pawchart:

      pipeline :browser do
        plug(:accepts, ["html"])
        plug(:fetch_session)
        plug(Samen.Web.SecureHeaders)
        ...
      end

  It sets Phoenix's `put_secure_browser_headers/2` set (`x-frame-options: SAMEORIGIN`,
  `x-content-type-options: nosniff`, `referrer-policy`, ...), a conservative
  `Content-Security-Policy`, and `strict-transport-security` on HTTPS requests. The reveal
  approval and impersonation screens can no longer be framed by another origin (clickjacking),
  and a PII product no longer ships without a CSP.

  ## The policy

      default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';
      img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none';
      base-uri 'self'; frame-ancestors 'self'

    * `script-src 'self'` — the shared root layout loads three vendored static bundles and no
      inline script (the old inline ⌘K listener moved into `app.js`, ADR-042 C2);
    * `style-src ... 'unsafe-inline'` — the UI kit styles components with `style=""` attributes;
    * `connect-src 'self'` — the LiveView websocket is same-origin;
    * `img-src` / `font-src` allow `data:` — the **session-replay player** embeds each frame as
      `<iframe srcdoc sandbox="">` (`Samen.Web.Replay.Renderer`), and a srcdoc document INHERITS
      the embedding page's policy on top of its own `default-src 'none'` CSP. Its inlined kit
      stylesheet carries `data:` fonts and images, so the parent must permit them or the frame
      renders unstyled. (The frame stays inert: its own policy and the empty `sandbox` still
      forbid scripts, connections, nested frames and forms.)
    * `frame-ancestors 'self'` — nobody else may frame an authenticated page.

  `form-action` is deliberately NOT set: a sign-in or checkout POST that redirects to an
  identity provider or Stripe would be blocked by `form-action 'self'` in Chromium.

  ## Options

    * `:csp` — extra source expressions per directive, e.g. a host that opted into a
      bring-your-own map tile provider: `csp: %{"img-src" => ["https://tiles.example.com"]}`.
      Directives are merged by name, never replaced, so a host cannot accidentally drop `'self'`.
    * the application env `config :samen_web, Samen.Web.SecureHeaders, csp: %{...}` is merged
      the same way (so a host extends the policy once, in config).

  A response that already carries a `content-security-policy` header (the host or a controller
  set its own) is left alone.
  """
  @behaviour Plug

  import Plug.Conn

  @base %{
    "default-src" => ["'self'"],
    "script-src" => ["'self'"],
    "style-src" => ["'self'", "'unsafe-inline'"],
    "img-src" => ["'self'", "data:"],
    "font-src" => ["'self'", "data:"],
    "connect-src" => ["'self'"],
    "object-src" => ["'none'"],
    "base-uri" => ["'self'"],
    "frame-ancestors" => ["'self'"]
  }

  @order ~w(default-src script-src style-src img-src font-src connect-src object-src base-uri frame-ancestors)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    # Decide BEFORE Phoenix's helper runs: since Phoenix 1.8 `put_secure_browser_headers/1`
    # itself writes a minimal `content-security-policy` (base-uri + frame-ancestors), so seeing a
    # header afterwards would no longer mean "the host set its own".
    host_csp? = get_resp_header(conn, "content-security-policy") != []

    # Phoenix 1.8 dropped `x-frame-options` from its set (CSP `frame-ancestors` replaced it);
    # keep it for browsers/proxies that predate CSP2 — the same-origin answer, so the two agree.
    conn = Phoenix.Controller.put_secure_browser_headers(conn, %{"x-frame-options" => "SAMEORIGIN"})
    conn = if host_csp?, do: conn, else: put_resp_header(conn, "content-security-policy", policy(opts))

    if conn.scheme == :https do
      put_resp_header(conn, "strict-transport-security", "max-age=63072000; includeSubDomains")
    else
      conn
    end
  end

  @doc "The `Content-Security-Policy` header value for these options."
  @spec policy(keyword()) :: String.t()
  def policy(opts \\ []) do
    configured = Application.get_env(:samen_web, __MODULE__, []) |> Keyword.get(:csp, %{})
    extra = Keyword.get(opts, :csp, %{})

    merged =
      Enum.reduce([configured, extra], @base, fn additions, acc ->
        Enum.reduce(additions, acc, fn {directive, sources}, acc ->
          Map.update(acc, to_string(directive), List.wrap(sources), &Enum.uniq(&1 ++ List.wrap(sources)))
        end)
      end)

    known = for d <- @order, Map.has_key?(merged, d), do: d
    custom = merged |> Map.keys() |> Enum.reject(&(&1 in @order)) |> Enum.sort()

    Enum.map_join(known ++ custom, "; ", fn d -> d <> " " <> Enum.join(merged[d], " ") end)
  end
end
