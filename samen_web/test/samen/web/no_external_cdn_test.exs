defmodule Samen.Web.NoExternalCdnTest do
  @moduledoc """
  Framework-wide no-external-CDN guard (T131). Extends the T55 map verifier's
  "NO EXTERNAL CDN" grep guard from the map component up to the GLOBAL chrome:
  the shared `samen_ui.css` stylesheet (inherited by samen_web + every generated
  app + demo/driftwood/pawchart) and the shared root layout DOM.

  Background: `samen_ui.css` shipped a Google Fonts `@import`
  (`https://fonts.googleapis.com/css2?...`) that fetched Inter + JetBrains Mono
  from an external host on EVERY page load — an IP leak to a third party, a broken
  air-gapped/offline story, and a violation of this codebase's own no-external-CDN
  invariant. T131 removed it by self-hosting the fonts (Latin-subset variable woff2);
  T133 then moved those woff2 out of the CSS into SEPARATE same-origin static files
  served at `/assets/fonts/*.woff2` (the stylesheet now `url()`s them, staying small).
  This test is the sabotage-refutable lock: re-introduce ANY external host in the
  global CSS or root layout and it fails — the same-origin `url(/assets/fonts/…)` refs
  stay green.

  Anti-tautology (per house discipline): every refutation is paired with a positive
  control proving the detector actually fires on a modeled violation, so a green here
  is never vacuous.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  # External-host indicators. NB: none of these can occur inside a base64 `data:`
  # URI payload — the base64 alphabet has no `:`/`(` and `://` requires a colon —
  # so the self-hosted inlined fonts do not false-positive. Verified empirically by
  # the "self-hosts the fonts locally" positive control below.
  @external_markers [
    "http://",
    "https://",
    "://",
    "fonts.googleapis.com",
    "fonts.gstatic.com",
    "googleapis",
    "gstatic",
    "@import",
    "url(http",
    "preconnect"
  ]

  defp external_hits(text) do
    lower = String.downcase(text)
    Enum.filter(@external_markers, &String.contains?(lower, &1))
  end

  defmodule HostWeb.Layouts do
    use Samen.Web.Layouts
  end

  defp render_root do
    render_component(&HostWeb.Layouts.root/1, inner_content: {:safe, "<main>INNER</main>"})
  end

  describe "the detector itself is not vacuous (positive controls)" do
    test "external_hits FLAGS a modeled Google-Fonts @import (the exact removed defect)" do
      modeled_violation =
        "@import url('https://fonts.googleapis.com/css2?family=Inter&display=swap');"

      hits = external_hits(modeled_violation)
      # The detector must catch it on multiple independent markers — if this ever
      # returns [], the guard below is a tautology and every other assertion is void.
      assert "@import" in hits
      assert "https://" in hits
      assert "fonts.googleapis.com" in hits
    end

    test "external_hits FLAGS a modeled preconnect / external <link>" do
      assert "preconnect" in external_hits(~s(<link rel="preconnect" href="https://x">))
      assert "https://" in external_hits(~s(<link rel="stylesheet" href="https://cdn/x.css">))
    end
  end

  describe "the GLOBAL stylesheet (samen_ui.css) reaches for zero external hosts" do
    test "the served samen_ui.css carries NO external host / scheme / @import" do
      css = File.read!(Samen.UI.stylesheet_path())
      hits = external_hits(css)

      assert hits == [],
             "samen_ui.css must make ZERO external fetch — found external markers: " <>
               "#{inspect(hits)}. A CDN/font @import or external url() was reintroduced."
    end

    test "positive control: samen_ui.css self-HOSTS the fonts via SAME-ORIGIN url() (T133), not base64 nor deleted" do
      # Proves the fix is genuine same-origin self-hosting, not a silent removal that
      # would drop the approved typeface. T133: the woff2 are SEPARATE static files the
      # @font-face `url()`s at /assets/fonts/*, NOT base64 `data:` URIs inlined in CSS.
      css = File.read!(Samen.UI.stylesheet_path())

      assert css =~ "@font-face"
      assert css =~ "font-family: 'Inter'"
      assert css =~ "font-family: 'JetBrains Mono'"
      assert css =~ "url('/assets/fonts/Inter-latin.var.woff2')"
      assert css =~ "url('/assets/fonts/JetBrainsMono-latin.var.woff2')"

      # The base64 blobs are GONE (the whole point of T133 — they can't cache separately
      # and bloated the critical CSS): no inlined font data URI remains.
      refute css =~ "data:font/woff2;base64,"
      # ...and the same-origin url() refs did not smuggle an external scheme back in.
      refute css =~ "://"
    end

    test "T133 PERF: dropping the inlined base64 fonts shrank the critical CSS by ~100KB" do
      # The base64-inlined Inter + JetBrains woff2 were ~104KB of the ~156KB stylesheet;
      # served as separate files, the CSS is now well under 80KB. A regression that
      # re-inlined a font (or shipped an un-minified blob) would blow this ceiling.
      bytes = File.stat!(Samen.UI.stylesheet_path()).size
      assert bytes < 80_000, "samen_ui.css is #{bytes} bytes — the fonts look re-inlined (T133 regressed)"
    end

    test "provenance + OFL license accompany the vendored fonts (self-host is licensed)" do
      dir = Path.join(Path.dirname(Samen.UI.stylesheet_path()), "fonts")
      assert File.exists?(Path.join(dir, "PROVENANCE.md"))

      for lic <- ["Inter-OFL.txt", "JetBrainsMono-OFL.txt"] do
        body = File.read!(Path.join(dir, lic))
        assert body =~ "SIL Open Font License"
      end
    end
  end

  describe "T133: the woff2 fonts are served SAME-ORIGIN under /assets/fonts (zero external fetch)" do
    # The exact Plug.Static clause hosts (driftwood/pawchart/generated apps) mount for
    # the samen_web UI kit — from samen_web's OWN priv, `only:` including `fonts`. This
    # proves a browser GET for the @font-face `url()` targets resolves 200 same-origin
    # (no CDN, no external host), which is what makes T133's url() refs valid.
    @font_static Plug.Static.init(
                   at: "/assets",
                   from: {:samen_web, "priv/static/assets"},
                   only: ~w(samen_ui.css app.js fonts)
                 )

    for font <- ~w(Inter-latin.var.woff2 JetBrainsMono-latin.var.woff2) do
      test "GET /assets/fonts/#{font} is served 200 from samen_web priv (same-origin)" do
        conn =
          Plug.Test.conn(:get, "/assets/fonts/#{unquote(font)}")
          |> Plug.Static.call(@font_static)

        assert conn.status == 200
        assert conn.halted
        # And the byte the @font-face url() points at exists on disk in the served dir.
        path = Path.join([Path.dirname(Samen.UI.stylesheet_path()), "fonts", unquote(font)])
        assert File.exists?(path)
      end
    end

    test "negative control: the `fonts` allowlist entry is load-bearing — without it the woff2 is NOT served" do
      bare =
        Plug.Static.init(
          at: "/assets",
          from: {:samen_web, "priv/static/assets"},
          only: ~w(samen_ui.css app.js)
        )

      conn =
        Plug.Test.conn(:get, "/assets/fonts/Inter-latin.var.woff2")
        |> Plug.Static.call(bare)

      # Plug.Static passes the request through untouched (a later plug 404s it); it is
      # NOT the 200-halt the `fonts` entry produces above — so the entry is meaningful.
      refute conn.halted
      refute conn.status == 200
    end
  end

  describe "the shared root layout DOM reaches for zero external hosts" do
    test "root/1 renders only local /assets refs — no external host or scheme" do
      html = render_root()
      hits = external_hits(html)

      assert hits == [],
             "the root layout must reference only local assets — found: #{inspect(hits)}"

      # Positive control: it DOES ship the local chrome (so the empty-hits result
      # above is meaningful, not an empty render).
      assert html =~ ~s(href="/assets/samen_ui.css")
      assert html =~ ~s(src="/assets/phoenix.min.js")
    end
  end
end
