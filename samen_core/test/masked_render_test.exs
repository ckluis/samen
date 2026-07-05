defmodule Samen.MaskedRenderTest do
  @moduledoc """
  T1.5 clause (a): `%Masked{}` renders `••••` across EVERY egress path and never
  leaks / never raises — including the Gate-0 fix-task-#1 HEEx/LiveView path.

  Egress paths covered:
    * `String.Chars` (`to_string/1`, interpolation)
    * `Inspect`
    * `Jason.Encoder` (JSON API / webhook)
    * `Phoenix.HTML.Safe` (HEEx `<%= @x %>`) — the Gate-0 mandatory fix
    * CSV-ish `IO.iodata` (`to_iodata/1`, `IO.iodata_to_binary/1`)

  The HEEx render test is a RED PATH: it renders a `%Masked{}` through the exact
  `Phoenix.HTML.Engine` path a HEEx `<%= %>` compiles to, asserts the output is
  `••••`, asserts it does not raise, and asserts the token never appears.
  """
  use ExUnit.Case, async: true

  alias Samen.Masked

  @token "vt_deadbeefdeadbeefdeadbeefdeadbeef"

  setup do
    {:ok, masked: Masked.new(@token, :emails)}
  end

  describe "to_string / interpolation" do
    test "renders ••••, never the token", %{masked: m} do
      assert to_string(m) == "••••"
      assert "#{m}" == "••••"
      refute "#{m}" =~ @token
    end
  end

  describe "Inspect" do
    test "renders #Masked<••••>, never the token", %{masked: m} do
      out = inspect(m)
      assert out == "#Masked<••••>"
      refute out =~ @token
    end
  end

  describe "Jason.Encoder" do
    test "encodes ••••, never the token", %{masked: m} do
      json = Jason.encode!(m)
      assert json == ~s("••••")
      refute json =~ @token
    end

    test "encodes ••••, never the token, when nested in a map", %{masked: m} do
      json = Jason.encode!(%{email: m, name: "Alice"})
      assert json =~ ~s("email":"••••")
      refute json =~ @token
    end
  end

  describe "CSV-ish IO.iodata (to_iodata + IO.iodata_to_binary)" do
    test "to_iodata renders ••••, never the token", %{masked: m} do
      assert Masked.to_iodata(m) == "••••"
      assert IO.iodata_to_binary(Masked.to_iodata(m)) == "••••"
      refute IO.iodata_to_binary([Masked.to_iodata(m)]) =~ @token
    end

    test "a CSV row built via to_string interpolation masks the field", %{masked: m} do
      row = "id,email\n1,#{m}\n"
      assert row == "id,email\n1,••••\n"
      refute row =~ @token
    end
  end

  # ===================================================================
  # RED PATH: HEEx / Phoenix.HTML.Safe render (Gate-0 fix task #1)
  # ===================================================================

  describe "RED PATH — HEEx render of a %Masked{} (Phoenix.HTML.Safe)" do
    test "Phoenix.HTML.Safe.to_iodata renders •••• and never raises/leaks", %{masked: m} do
      # This is the EXACT protocol call a HEEx `<%= @person.email %>` makes.
      iodata = Phoenix.HTML.Safe.to_iodata(m)
      out = IO.iodata_to_binary(iodata)
      assert out == "••••"
      refute out =~ @token
    end

    test "a real HEEx-style template renders •••• and never raises/leaks", %{masked: m} do
      # Render through Phoenix.HTML.Engine — the engine HEEx compiles `<%= %>`
      # interpolations down to. `<%= @email %>` calls Phoenix.HTML.Safe.to_iodata/1
      # on the value; without the %Masked{} impl this raises Protocol.UndefinedError
      # (the pre-fix behaviour the Gate-0 report predicted). With the impl it is ••••.
      template = "<span><%= @email %></span>"

      rendered =
        template
        |> EEx.eval_string([assigns: %{email: m}], engine: Phoenix.HTML.Engine)
        |> Phoenix.HTML.safe_to_string()

      assert rendered == "<span>••••</span>"
      refute rendered =~ @token
    end

    test "the impl exists (not the pre-fix Protocol.UndefinedError raise)", %{masked: m} do
      # Guards against a regression to the S0.5 gap: no impl → raise.
      assert Code.ensure_loaded?(Phoenix.HTML.Safe)

      impl =
        try do
          Phoenix.HTML.Safe.impl_for!(m)
          :ok
        rescue
          Protocol.UndefinedError -> :missing
        end

      assert impl == :ok,
             "Phoenix.HTML.Safe must be implemented for %Masked{} (Gate-0 fix #1) — " <>
               "without it a HEEx render raises Protocol.UndefinedError instead of ••••"
    end
  end

  # ===================================================================
  # Structural: %Masked{} carries no plaintext (leak-by-omission is impossible)
  # ===================================================================

  describe "structural: %Masked{} carries no plaintext" do
    test "the struct fields are only a token + label — no plaintext key exists", %{masked: m} do
      assert Map.keys(m) |> Enum.sort() == [:__struct__, :label, :token]
      # There is no field that could hold plaintext.
      refute Map.has_key?(m, :plaintext)
      refute Map.has_key?(m, :value)
    end
  end
end
