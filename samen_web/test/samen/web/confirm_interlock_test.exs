defmodule Samen.Web.ConfirmInterlockTest do
  @moduledoc """
  The kit renders `data-confirm` on every destructive control; the served client script
  (`samen_web/priv/static/assets/app.js`) is what asks the question and refuses the event.

    * the script carries the capture-phase click + submit handler, proven by running the
      real file against a DOM stub under node (refusal stops the event, acceptance lets it
      through, an element without the attribute is untouched);
    * every layout and host endpoint that serves the framework JS serves
      `app.js` with it (the generator templates are checked in samen_core's `EndpointTemplateServesAppJsTest`), so no
      host or generated app ships the LiveView client without the guard.
  """
  use ExUnit.Case, async: true

  @repo Path.expand("../../../..", __DIR__)
  @app_js Path.join(@repo, "samen_web/priv/static/assets/app.js")
  @harness Path.expand("../../support/confirm_interlock_harness.js", __DIR__)

  defp harness do
    node = System.find_executable("node") || flunk("node is required for the app.js handler test")

    {out, 0} =
      System.cmd(node, [@harness, @app_js], env: [{"NODE_OPTIONS", ""}], stderr_to_stdout: true)

    Jason.decode!(out)
  end

  describe "the served app.js handler (run against a DOM stub)" do
    test "a refused click asks the attribute's text and stops the event before it reaches LiveView" do
      r = harness()["refuse_click"]
      assert r["asked"] == ["Kill it?"]
      assert r["prevented"] and r["stopped"]
      refute r["reached"]
    end

    test "an accepted click is let through unmodified (positive control)" do
      r = harness()["accept_click"]
      assert r["asked"] == ["Kill it?"]
      refute r["prevented"] or r["stopped"]
      assert r["reached"]
    end

    test "an element without data-confirm is never asked and never touched" do
      for key <- ["plain_click", "plain_submit"] do
        r = harness()[key]
        assert r["asked"] == []
        refute r["prevented"] or r["stopped"]
        assert r["reached"]
      end
    end

    test "a click on a child, and a refused link, are stopped like the control itself" do
      for key <- ["inner_click_refused", "link_refused"] do
        r = harness()[key]
        assert length(r["asked"]) == 1
        assert r["prevented"] and r["stopped"]
        refute r["reached"]
      end
    end

    test "a form is confirmed on submit: refusal stops it, acceptance lets it through, a button click is not asked twice" do
      h = harness()
      assert h["form_refuse"]["asked"] == ["Send it?"]
      assert h["form_refuse"]["stopped"]
      refute h["form_refuse"]["reached"]
      assert h["form_accept"]["reached"]
      refute h["form_accept"]["stopped"]
      assert h["form_button_click"]["asked"] == []
      assert h["form_button_click"]["reached"]
    end

    test "the handler is a document-level capture listener (so later-patched elements are covered)" do
      js = File.read!(@app_js)
      assert js =~ ~s|document.addEventListener("click"|
      assert js =~ ~s|document.addEventListener("submit"|
      assert js =~ "stopImmediatePropagation"
      assert js =~ "window.confirm"
    end
  end

  describe "everything that serves the framework JS serves app.js with it" do
    @served_globs ["samen_web/lib/**/*.ex", "driftwood/lib/**/*.ex", "pawchart/lib/**/*.ex",
                   "demo/lib/**/*.ex"]

    defp serves_js_without_app?(text),
      do: text =~ "phoenix_live_view.min.js" and not (text =~ "app.js")

    test "no layout or host endpoint serves the LiveView client without app.js" do
      files = Enum.flat_map(@served_globs, &Path.wildcard(Path.join(@repo, &1)))
      serving = Enum.filter(files, &(File.read!(&1) =~ "phoenix_live_view.min.js"))

      # The set is non-empty and contains the layout, both verticals and the template.
      for needle <- ["layouts.ex", "driftwood_web/endpoint.ex", "pawchart_web/endpoint.ex"] do
        assert Enum.any?(serving, &String.ends_with?(&1, needle)), "#{needle} not found serving the JS"
      end

      offenders = Enum.filter(serving, &serves_js_without_app?(File.read!(&1)))
      assert offenders == [], "serves the LiveView client without app.js: #{inspect(offenders)}"
    end

    test "the detector fires on a modeled host that omits app.js (positive control)" do
      assert serves_js_without_app?(~s|only: ~w(phoenix_live_view.min.js samen_ui.css)|)
      refute serves_js_without_app?(~s|only: ~w(phoenix_live_view.min.js app.js)|)
    end
  end
end
