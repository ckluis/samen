defmodule Samen.VaultTokenAssertTest do
  @moduledoc """
  `Samen.VaultTokenAssert` is the one "no vault token here" assertion, and it must be both:

    * STRICT — a real token (grammar `vt_` + 32 lowercase hex, the `Samen.Vault.generate_token/0` shape) fails in
      text, in an attribute, in a `data-` value, in JSON, and even inside a CSRF value; a planted canary
      (`vt_realtoken`) fails everywhere except inside the framework's own random-token carriers;
    * NOT FLAKY — a page whose random CSRF / LiveView tokens happen to contain `vt_` is clean. The bare
      `refute html =~ "vt_"` it replaces fails on exactly that page (asserted below, so the control is live).
  """
  use ExUnit.Case, async: true

  import Samen.VaultTokenAssert

  defp token, do: Samen.Vault.generate_token()
  defp fails?(fun), do: match?({:error, _}, run(fun))

  defp run(fun) do
    fun.()
    :ok
  rescue
    e in ExUnit.AssertionError -> {:error, e.message}
  end

  # A page whose RANDOM framework tokens each contain `vt_` (what the CSRF/LiveView seams produce by chance).
  defp unlucky_page do
    csrf = "UDsgR3RwGjsfFU0zDQwJAkIwByBELCMeevxwCBiwyT5QxAjvt_ie7DRh"

    """
    <html><head><meta name="csrf-token" content="#{csrf}"></head>
    <body><div id="phx-Fvt_abcdefgh" data-phx-session="SFMyNTY.g2gDvt_bgQ.sig" data-phx-static="SFMyNTY.vt_x.s">
    <form method="post" action="/session/org/1"><input type="hidden" name="_csrf_token" value="#{csrf}">
    <input value="#{csrf}" name="_csrf_token" type="hidden"><button>Workspace</button></form>
    <p>Account detail</p></div></body></html>
    """
  end

  describe "not flaky: random framework tokens containing vt_" do
    test "the bare substring check the helper replaces FAILS on the unlucky page (the control is live)" do
      assert unlucky_page() =~ "vt_"
    end

    test "the unlucky page is clean" do
      assert unlucky_page() == refute_vault_token(unlucky_page())
      assert leaks(unlucky_page()) == []
    end
  end

  describe "strict: a real token fails in every position" do
    test "in text, an attribute, a data- value, JSON and a log line" do
      t = token()

      for html <- [
            "<p>#{t}</p>",
            ~s(<a href="/x?token=#{t}">x</a>),
            ~s(<div data-token="#{t}"></div>),
            ~s(<div data-payload='{"email":"#{t}"}'></div>),
            ~s({"email":"#{t}"}),
            "sent to #{t} ok"
          ] do
        assert fails?(fn -> refute_vault_token(html) end), "a real token was missed in: #{html}"
      end
    end

    test "a real token inside a CSRF value, a phx session or a phx id still fails (the grammar arm sees every byte)" do
      t = token()

      for html <- [
            ~s(<input type="hidden" name="_csrf_token" value="#{t}">),
            ~s(<meta name="csrf-token" content="#{t}">),
            ~s(<div data-phx-session="#{t}"></div>),
            ~s(<div id="phx-#{t}"></div>)
          ] do
        assert fails?(fn -> refute_vault_token(html) end), "a real token was missed in: #{html}"
      end
    end

    test "a planted canary (vt_realtoken) fails in text, an attribute and JSON, and next to an unlucky CSRF token" do
      for html <- [
            "<p>vt_realtoken</p>",
            ~s(<a title="vt_realtoken">x</a>),
            ~s({"email":"vt_realtoken"}),
            unlucky_page() <> "<p>vt_leak</p>"
          ] do
        assert fails?(fn -> refute_vault_token(html) end), "a canary was missed in: #{html}"
      end
    end

    test "the failure message carries the caller's message and the evidence" do
      {:error, msg} = run(fn -> refute_vault_token("x #{token()} y", "the DOM leaked") end)
      assert msg =~ "the DOM leaked"
      assert msg =~ "vt_"
    end

    test "uppercase hex is not the grammar but the prefix arm still catches it in text" do
      assert fails?(fn -> refute_vault_token("<p>vt_" <> String.duplicate("A", 32) <> "</p>") end)
    end

    test "clean text passes and is returned" do
      assert "hello" == refute_vault_token("hello")
      assert "<p>•••• </p>" == refute_vault_token("<p>•••• </p>")
    end
  end

  describe "only text is accepted" do
    test "nil, atoms, numbers, maps and non-iodata lists flunk with a message naming the input (refute AND assert)" do
      for bad <- [nil, :ok, 42, %{"body" => "x"}, [:not, :iodata], {:ok, "x"}] do
        assert {:error, msg} = run(fn -> refute_vault_token(bad) end), "refute accepted #{inspect(bad)}"
        assert msg =~ "binary or iodata", msg
        assert {:error, _} = run(fn -> assert_vault_token(bad) end), "assert accepted #{inspect(bad)}"
        assert {:error, _} = run(fn -> leaks(bad) end), "leaks accepted #{inspect(bad)}"
      end
    end

    test "iodata is read as the text it spells (control), and a token inside it still fails" do
      clean = ["clean ", ["text", ?!]]
      assert clean == refute_vault_token(clean)
      t = token()
      assert fails?(fn -> refute_vault_token(["a ", [t]]) end)
      assert [^t] = assert_vault_token(["a ", [t]])
    end
  end

  describe "the phx- blanking is anchored to an id attribute" do
    test "a canary after a phx- word that is not an id=\"phx-…\" attribute fails; the real id carrier is blanked" do
      assert fails?(fn -> refute_vault_token("<p>phx-vt_canary1234</p>") end)
      assert fails?(fn -> refute_vault_token(~s(<div data-id="phx-vt_canary1234"></div>)) end)
      assert fails?(fn -> refute_vault_token(~s(<div class="phx-vt_canary1234"></div>)) end)
      assert "<div id=\"phx-Fvt_abcdefgh\"></div>" == refute_vault_token("<div id=\"phx-Fvt_abcdefgh\"></div>")
    end
  end

  describe "assert_vault_token/2 (presence, exact)" do
    test "finds a real token, in order" do
      [a, b] = [token(), token()]
      assert [^a, ^b] = assert_vault_token(~s(<i data-t="#{a}"></i> and #{b}))
    end

    test "a bare vt_ or a short/uppercase look-alike does not satisfy it" do
      for text <- [
            "vt_",
            "vt_abc",
            "vt_" <> String.duplicate("A", 32),
            "vt_" <> String.duplicate("a", 31)
          ] do
        assert fails?(fn -> assert_vault_token(text) end), "accepted #{inspect(text)}"
      end
    end
  end

  test "Samen.Vault.tokens_in/1 and token?/1 share one grammar" do
    t = token()
    assert Samen.Vault.token?(t)
    assert [^t] = Samen.Vault.tokens_in("a #{t} b")
    assert [] == Samen.Vault.tokens_in("vt_" <> String.duplicate("g", 32))
    refute Samen.Vault.token?("x" <> t)
    assert [^t] = Samen.Vault.tokens_in("x" <> t)
  end
end
