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
  invariant. T131 removed it by self-hosting the fonts (Latin-subset variable woff2
  base64-inlined into the stylesheet). This test is the sabotage-refutable lock:
  re-introduce ANY external host in the global CSS or root layout and it fails.

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

    test "positive control: samen_ui.css self-HOSTS the fonts locally (not merely deleted)" do
      # Proves the fix is genuine self-hosting, not a silent removal that would drop
      # the approved typeface. The fonts are inlined as base64 woff2 `data:` URIs.
      css = File.read!(Samen.UI.stylesheet_path())

      assert css =~ "@font-face"
      assert css =~ "font-family: 'Inter'"
      assert css =~ "font-family: 'JetBrains Mono'"
      assert css =~ "data:font/woff2;base64,"
      # ...and those inlined data: URIs did not smuggle an external scheme back in.
      refute css =~ "://"
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
