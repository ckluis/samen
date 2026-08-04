defmodule Samen.Web.GeoTilesTest do
  @moduledoc """
  The bring-your-tiles seam (`Samen.Web.Geo.TileSource`, G7/T55) — the FAIL-HONEST adapter
  contract (ADR-014/024/026): unconfigured returns `{:error, :not_configured}`, NEVER a fake
  `{:ok, _}`, NEVER a default/hardcoded external tile host. Enabling tiles is a deliberate HOST
  opt-in that names the host's OWN url; the default makes ZERO external call (no CDN leak).
  """
  use ExUnit.Case, async: false

  alias Samen.Web.Geo.TileSource

  setup do
    prev = Application.get_env(:samen_web, TileSource)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:samen_web, TileSource)
  defp restore(v), do: Application.put_env(:samen_web, TileSource, v)

  test "UNCONFIGURED (default): resolve/0 is the honest not_configured error — no fake ok, no default host" do
    Application.delete_env(:samen_web, TileSource)

    assert TileSource.resolve() == {:error, :not_configured}
    refute TileSource.configured?()
  end

  test "HOST OPT-IN via app config: a self-hosted url template turns street-level ON" do
    Application.put_env(:samen_web, TileSource,
      url_template: "https://tiles.host-internal.example/{z}/{x}/{y}.png",
      attribution: "© host"
    )

    assert {:ok, cfg} = TileSource.resolve()
    assert cfg.url_template == "https://tiles.host-internal.example/{z}/{x}/{y}.png"
    assert cfg.attribution == "© host"
    assert TileSource.configured?()
  end

  test "HOST OPT-IN via explicit override (test injection) beats app config" do
    Application.delete_env(:samen_web, TileSource)

    assert {:ok, cfg} = TileSource.resolve(url_template: "https://tiles.override.example/{z}/{x}/{y}.png")
    assert cfg.url_template =~ "tiles.override.example"
  end

  test "FAIL-HONEST: an empty/blank url template is NOT a configured success" do
    Application.put_env(:samen_web, TileSource, url_template: "   ")
    assert TileSource.resolve() == {:error, :not_configured}

    Application.put_env(:samen_web, TileSource, url_template: nil)
    assert TileSource.resolve() == {:error, :not_configured}

    Application.put_env(:samen_web, TileSource, attribution: "no template here")
    assert TileSource.resolve() == {:error, :not_configured}
  end

  test "NO DEFAULT EXTERNAL HOST: with no host config, resolve NEVER produces a url (zero surprise calls)" do
    Application.delete_env(:samen_web, TileSource)

    # Behavioral guarantee: absent an explicit host opt-in, there is no {:ok, url} anywhere —
    # so nothing downstream can ever emit a default/CDN tile host. Also honest for a map config.
    assert {:error, :not_configured} = TileSource.resolve()
    assert {:error, :not_configured} = TileSource.resolve(config: %{attribution: "x"})
    assert {:ok, _} = TileSource.resolve(config: %{url_template: "https://self.example/{z}/{x}/{y}"})
  end
end
