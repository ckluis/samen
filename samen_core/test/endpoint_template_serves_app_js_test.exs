defmodule Samen.EndpointTemplateServesAppJsTest do
  @moduledoc """
  The generator's endpoint template serves the framework's `app.js` (the file that carries the `data-confirm` guard) next to
  the LiveView client it serves, so a generated app never ships the client without the guard. The host endpoints and the
  root layout are checked in samen_web's `Samen.Web.ConfirmInterlockTest`.
  """
  use ExUnit.Case, async: true

  @templates Path.expand("../priv/templates", __DIR__)

  defp serves_js_without_app?(text),
    do: text =~ "phoenix_live_view.min.js" and not (text =~ "app.js")

  test "every generator template that serves the LiveView client serves app.js with it" do
    serving =
      for file <- Path.wildcard(Path.join(@templates, "**/*.eex")),
          File.read!(file) =~ "phoenix_live_view.min.js",
          do: file

    assert Enum.any?(serving, &String.ends_with?(&1, "endpoint_ex.eex")), "the endpoint template no longer serves the client"
    assert Enum.filter(serving, &serves_js_without_app?(File.read!(&1))) == []
  end

  test "the detector fires on a modeled template that omits app.js (positive control)" do
    assert serves_js_without_app?(~s|only: ~w(phoenix_live_view.min.js)|)
    refute serves_js_without_app?(~s|only: ~w(phoenix_live_view.min.js) / only: ~w(samen_ui.css app.js fonts)|)
  end
end
