defmodule Samen.Web.Fleet.PublicStatus do
  @moduledoc """
  T166 / ADR-050 (G11) — the PUBLIC, unauthenticated, rate-limited status page.
  The enforcement half of the `Samen.Web.FleetStatusController` seam (the
  `Samen.Web.Fleet.Ingress` pattern: route wiring in the controller, rules here).

  ## Posture

    * **Unauthenticated by design.** There is no actor, no session, no cookie and
      no CSRF on this path. It is mounted in a host's PUBLIC router scope, exactly
      like the `:kb` portal and `:csat` response pages.
    * **It grants nothing.** The request's identity is not consulted because there
      is none; the substrate read runs as the internal aggregate actor
      (`Samen.Aggregate.Actor.new/0`, the same actor the cockpit's own read uses),
      resolved SERVER-side. A request parameter can therefore never widen what is
      published — `index/2` ignores params entirely.
    * **Rate-limited through the one shared seam** (`Samen.Web.RateLimit`, ADR-038
      §6.1 — never a parallel implementation), keyed per remote IP. Over the
      window is a bare `429` with an EMPTY body, so the response cannot be used to
      tell a cockpit that publishes something from one that publishes nothing.
    * **Fails closed.** No namespace, or a namespace that cannot be read, is a
      `503` that says "unavailable" — not an empty 200, which a reader would take
      as an all-clear. ADR-014/024 fail-honest.

  ## What crosses the plane

  Only what `Samen.Fleet.PublicStatus` lets through: an app slug in the bounded
  operator shape (or `••••`) and a status from the closed public vocabulary. This
  module renders those two fields and its own operator-authored chrome. There is no
  branch here that can reach `app_id`, `display_name`, `base_url`, `received_at`,
  `transport` or the producer `payload`, because it never sees them — the narrowing
  happens in samen_core, one layer below the renderer, so a template change cannot
  widen it.

  Both strings that reach the HTML are escaped (`Plug.HTML.html_escape/1`): the
  bounded slug (belt-and-braces — the shape already excludes `<`) and the mount's
  own title label.

  ## Not published here (deferred, ADR-050 §7)

  Uptime percentages and an incident TIMELINE are NOT in this increment. They need
  a retention window over `flt_report` and a bounded incident-derivation rule of
  their own, and shipping an "uptime: 100%" cell computed from whatever reports
  happen to be in the table would be exactly the fabricated-completeness this repo
  refuses. The page renders CURRENT status only and says nothing about history.
  """

  import Plug.Conn

  alias Samen.Fleet.PublicStatus, as: Projection
  alias Samen.Web.RateLimit

  @default_title "Service status"

  # Short, so a status page survives a stampede without going stale enough to lie.
  @cache_control "public, max-age=15"

  @doc """
  Serve the public status page for the mount's fleet `namespace`.

  Options (baked into the route's `private` by
  `Samen.Web.Router.samen_fleet_status_route/1`):

    * `:namespace` — the `Samen.Fleet.Scope`-mounted Ash domain. Absent -> 503.
    * `:labels` — optional operator-authored chrome, currently `%{title: "..."}`.
  """
  @spec index(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def index(conn, opts) do
    with :ok <- rate_limit(conn),
         {:ok, namespace} <- namespace(opts),
         {:ok, view} <- Projection.read(namespace, actor: Samen.Aggregate.Actor.new()) do
      html(conn, 200, page(view, title(opts)))
    else
      {:error, :rate_limited} ->
        # Empty body on purpose: a 429 must not differentiate one cockpit's
        # published set from another's, and there is nothing a client can do with
        # detail here that backing off does not already cover.
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "")

      {:error, _reason} ->
        html(conn, 503, unavailable_page(title(opts)))
    end
  end

  # ---------------------------------------------------------------------------
  # Gates
  # ---------------------------------------------------------------------------

  defp rate_limit(conn), do: RateLimit.check(:public_status_ip, :ip, ip(conn))

  # The ONLY value keyed into the bucket: the remote IP, which ADR-038 §6.2 already
  # admits as a non-PII ephemeral counter key. Never persisted anywhere by this path.
  defp ip(%Plug.Conn{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    remote_ip |> :inet.ntoa() |> to_string()
  end

  defp ip(_conn), do: "unknown"

  defp namespace(opts) do
    case Keyword.get(opts, :namespace) do
      ns when is_atom(ns) and not is_nil(ns) -> {:ok, ns}
      _ -> {:error, :not_configured}
    end
  end

  defp title(opts) do
    opts
    |> Keyword.get(:labels, %{})
    |> Map.get(:title, @default_title)
    |> to_string()
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(status, body)
  end

  defp page(%{entries: entries, overall: overall}, title) do
    document(title, """
    <h1>#{esc(title)}</h1>
    <p class="overall #{cls(overall)}">#{esc(headline(overall))}</p>
    #{components(entries)}
    <p class="note">Current status only. This page reports no history and no tenant information.</p>
    """)
  end

  defp unavailable_page(title) do
    document(title, """
    <h1>#{esc(title)}</h1>
    <p class="overall down">Status is temporarily unavailable.</p>
    <p class="note">This page could not read its own status source, so it is not reporting one.</p>
    """)
  end

  defp components([]) do
    ~s(<p class="note">No components are published on this page.</p>)
  end

  defp components(entries) do
    rows =
      entries
      |> Enum.map_join("\n", fn %{slug: slug, status: status} ->
        ~s(<li class="#{cls(status)}"><span class="slug">#{esc(slug)}</span>) <>
          ~s(<span class="state">#{esc(label(status))}</span></li>)
      end)

    ~s(<ul class="components">\n#{rows}\n</ul>)
  end

  # The public vocabulary's display strings. Deliberately NOT the internal words:
  # `build_row/3`'s `:stale` / `:unreachable` / `:revoked` / `:deregistered` never
  # appear on this page in any spelling.
  defp label(:operational), do: "Operational"
  defp label(:degraded), do: "Degraded"
  defp label(:down), do: "Down"
  defp label(:maintenance), do: "Maintenance"
  defp label(:unknown), do: "Unknown"
  defp label(_other), do: "Down"

  defp headline(:operational), do: "All published components are operational."
  defp headline(:degraded), do: "Some published components are degraded."
  defp headline(:down), do: "Some published components are down."
  defp headline(:maintenance), do: "Some published components are in maintenance."
  defp headline(:unknown), do: "No components are published on this page."
  defp headline(_other), do: "Some published components are down."

  defp cls(status) when is_atom(status), do: "s-#{status}"

  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()

  # Self-contained: no external stylesheet, script, font or image, so the page has
  # no third-party surface and works on a first paint under load.
  defp document(title, body) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(title)}</title>
    <style>
    :root{color-scheme:light dark}
    body{margin:0;padding:2rem 1rem;font:16px/1.5 system-ui,-apple-system,sans-serif}
    main{max-width:40rem;margin:0 auto}
    h1{font-size:1.4rem;margin:0 0 1rem}
    .overall{font-weight:600;margin:0 0 1.5rem}
    .components{list-style:none;margin:0;padding:0;border-top:1px solid #8884}
    .components li{display:flex;justify-content:space-between;gap:1rem;padding:.65rem 0;border-bottom:1px solid #8884}
    .slug{font-family:ui-monospace,monospace}
    .state{font-variant-numeric:tabular-nums}
    .s-operational .state,.overall.s-operational{color:#1a7f37}
    .s-degraded .state,.overall.s-degraded{color:#9a6700}
    .s-down .state,.overall.s-down,.overall.down{color:#b3261e}
    .note{color:#8889;font-size:.85rem;margin-top:1.5rem}
    </style>
    </head>
    <body><main>
    #{body}
    </main></body>
    </html>
    """
  end
end
