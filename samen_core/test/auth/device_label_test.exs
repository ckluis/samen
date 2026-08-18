defmodule Samen.Auth.DeviceLabelTest do
  @moduledoc """
  ADR-035 §4.3 — `device_label` is a BOUNDED browser-family + OS-family string
  derived from the raw User-Agent header; the raw UA itself is never stored.
  Proves the derivation is deterministic + bounded (never echoes raw input)
  and degrades honestly (`"Unknown device"`) rather than guessing on unknown UAs.
  """
  use ExUnit.Case, async: true

  alias Samen.Auth.DeviceLabel

  @chrome_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @safari_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
  @firefox_win "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
  @edge_win "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
  @safari_iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1"
  @chrome_android "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

  describe "known browser/OS combinations" do
    test "Chrome on macOS" do
      assert DeviceLabel.from_user_agent(@chrome_mac) == "Chrome on macOS"
    end

    test "Safari on macOS (Chrome/Edge/Opera tokens correctly NOT matched)" do
      assert DeviceLabel.from_user_agent(@safari_mac) == "Safari on macOS"
    end

    test "Firefox on Windows" do
      assert DeviceLabel.from_user_agent(@firefox_win) == "Firefox on Windows"
    end

    test "Edge is distinguished from the Chrome/Safari tokens its own UA carries" do
      assert DeviceLabel.from_user_agent(@edge_win) == "Edge on Windows"
    end

    test "Safari on iOS" do
      assert DeviceLabel.from_user_agent(@safari_iphone) == "Safari on iOS"
    end

    test "Chrome on Android" do
      assert DeviceLabel.from_user_agent(@chrome_android) == "Chrome on Android"
    end
  end

  describe "RED PATH — unrecognized/absent input degrades honestly, never echoes raw UA" do
    test "nil falls back to the fixed unknown label" do
      assert DeviceLabel.from_user_agent(nil) == "Unknown device"
    end

    test "an empty string falls back to the fixed unknown label" do
      assert DeviceLabel.from_user_agent("") == "Unknown device"
    end

    test "a gibberish UA falls back to the fixed unknown label, never echoed verbatim" do
      raw = "SomeWeirdBotClient/9.9 (never seen before)"
      label = DeviceLabel.from_user_agent(raw)
      assert label == "Unknown device"
      refute label == raw
    end

    test "ANTI-TAUTOLOGY: the label is a fixed bounded string, not a passthrough of raw input" do
      # If `from_user_agent/1` degraded to echoing raw input, THIS assertion would
      # fail — proving the "Unknown device" branch is a real, reachable fallback
      # and not a vacuously-true check.
      raw = "curl/8.4.0"
      refute DeviceLabel.from_user_agent(raw) =~ "curl"
    end
  end

  describe "non-PII by construction" do
    test "the output never contains the raw UA substring for a recognized client" do
      # The whole point of the derivation: "Chrome/120.0.0.0" (a fingerprinting-grade
      # version string) never survives into the stored label.
      refute DeviceLabel.from_user_agent(@chrome_mac) =~ "120.0.0.0"
      refute DeviceLabel.from_user_agent(@chrome_mac) =~ "Intel"
    end
  end
end
