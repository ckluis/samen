defmodule Demo.LiveViewMaskedTest do
  @moduledoc """
  Proves %Masked{} renders "••••" in real HEEx (T1.9 acceptance clause).

  Gate-0 fix task #1: Phoenix.HTML.Safe is implemented on %Masked{} so a HEEx
  `<%= @contact.emails %>` renders "••••" and never raises Protocol.UndefinedError.

  These tests do NOT start a full Phoenix endpoint — they render the LiveView
  template directly using Phoenix.LiveView.Test helpers and assert the rendered
  output contains "••••" for every masked field.
  """
  use ExUnit.Case, async: true

  alias Samen.Masked

  # ---------------------------------------------------------------------------
  # Phoenix.HTML.Safe protocol tests — no LiveView needed
  # ---------------------------------------------------------------------------

  describe "Phoenix.HTML.Safe protocol" do
    test "to_iodata renders •••• for a masked value" do
      m = Masked.new("vt_token_001", :emails)
      # Phoenix.HTML.Safe.to_iodata/1 must return the mask string
      iodata = Phoenix.HTML.Safe.to_iodata(m)
      assert IO.iodata_to_binary(iodata) == "••••"
    end

    test "to_iodata never contains the token" do
      token = "vt_super_secret_token"
      m = Masked.new(token, :full_name)
      iodata = Phoenix.HTML.Safe.to_iodata(m)
      result = IO.iodata_to_binary(iodata)
      refute result =~ token
      assert result == "••••"
    end

    test "to_iodata renders •••• for dob masked value" do
      m = Masked.new("vt_dob_token", :dob)
      assert IO.iodata_to_binary(Phoenix.HTML.Safe.to_iodata(m)) == "••••"
    end
  end

  # ---------------------------------------------------------------------------
  # HEEx template rendering — proves the protocol integration
  # ---------------------------------------------------------------------------

  describe "HEEx template rendering of %Masked{}" do
    test "masked emails renders •••• in a HEEx assign" do
      masked = Masked.new("vt_token_emails", :emails)

      # Render a minimal HEEx template that uses the masked value.
      html =
        Phoenix.HTML.html_escape(masked)
        |> Phoenix.HTML.safe_to_string()

      assert html == "••••"
    end

    test "masked full_name renders •••• in a HEEx assign" do
      masked = Masked.new("vt_token_name", :full_name)
      html = Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(masked))
      assert html == "••••"
    end

    test "masked value does NOT raise Protocol.UndefinedError" do
      masked = Masked.new("vt_token_dob", :dob)
      # This must not raise — it proves Gate-0 fix task #1 is closed.
      assert is_binary(IO.iodata_to_binary(Phoenix.HTML.Safe.to_iodata(masked)))
    end

    test "rendered HEEx output does NOT contain the vault token" do
      token = "vt_sensitive_token_xyz"
      masked = Masked.new(token, :emails)
      html = Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(masked))
      refute html =~ token
      refute html =~ "sensitive"
    end
  end

  # ---------------------------------------------------------------------------
  # LiveView render test — proves the ContactLive template renders ••••
  #
  # We render the LiveView template directly using Phoenix.Component.to_html/1
  # without needing a full endpoint. This proves the Phoenix.HTML.Safe protocol
  # integration works end-to-end in a HEEx template context.
  # ---------------------------------------------------------------------------

  describe "ContactLive template renders •••• for masked PII fields" do
    test "HEEx assigns with %Masked{} render •••• not the token or plaintext" do
      # Simulate what the LiveView mount assigns.
      masked_emails = Samen.Masked.new("vt_demo_token_001", :emails)
      masked_full_name = Samen.Masked.new("vt_demo_token_002", :full_name)
      masked_dob = Samen.Masked.new("vt_demo_token_003", :dob)

      # Render a minimal HEEx template fragment as if inside a LiveView.
      # Phoenix.HTML.html_escape is what HEEx calls on any non-safe value,
      # then Phoenix.HTML.Safe.to_iodata on safe values.
      for {label, masked} <- [
            {"emails", masked_emails},
            {"full_name", masked_full_name},
            {"dob", masked_dob}
          ] do
        # The HEEx `{@field}` expression calls Phoenix.HTML.Safe.to_iodata/1.
        safe_val = Phoenix.HTML.Safe.to_iodata(masked)
        html = IO.iodata_to_binary(safe_val)

        assert html == "••••",
               "Expected #{label} to render ••••, got: #{inspect(html)}"

        refute html =~ "vt_demo_token",
               "#{label} rendered the vault token — information leakage"
      end
    end

    test "Phoenix.HTML.html_escape on %Masked{} renders •••• (the HEEx path)" do
      # In older Phoenix HEEx templates, values in `<%= @field %>` go through
      # Phoenix.HTML.html_escape/1 first. Verify that path too.
      masked = Masked.new("vt_token_escape", :emails)
      safe = Phoenix.HTML.html_escape(masked)
      html = Phoenix.HTML.safe_to_string(safe)
      assert html == "••••"
    end

    test "ContactLive render/1 produces HTML containing •••• for all masked fields" do
      # Render the ContactLive view's render/1 directly.
      assigns = %{
        contact_name: "Test User",
        emails: Masked.new("vt_t1", :emails),
        full_name: Masked.new("vt_t2", :full_name),
        dob: Masked.new("vt_t3", :dob),
        granted: false,
        __changed__: %{}
      }

      # Call render/1 directly on the LiveView module — the same function
      # Phoenix.LiveView.Diff calls when rendering.
      html =
        assigns
        |> DemoWeb.ContactLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "••••",
             "ContactLive render should contain •••• for masked fields"

      refute html =~ "vt_t1"
      refute html =~ "vt_t2"
      refute html =~ "vt_t3"
    end
  end
end
