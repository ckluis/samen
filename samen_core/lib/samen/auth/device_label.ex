defmodule Samen.Auth.DeviceLabel do
  @moduledoc """
  ADR-035 §4.3 — derives the Session row's `device_label` from a request's raw
  `User-Agent` header: a bounded "<browser family> on <OS family>" string.
  The RAW user-agent is NEVER stored (mask-unknown-by-default posture) — this
  module's job is exactly to reduce the (potentially fingerprinting-grade) raw
  string down to a coarse, non-PII pair before anything touches the DB. Called
  once, at session create; the raw header never reaches `Samen.Auth.SessionCreate`.
  """

  @unknown "Unknown device"

  @doc """
  Derive a bounded device label from a raw `User-Agent` header value (or `nil`,
  e.g. a non-browser client). Never raises; an unrecognized/absent UA falls
  back to the fixed `"Unknown device"` label rather than echoing raw input.
  """
  @spec from_user_agent(String.t() | nil) :: String.t()
  def from_user_agent(nil), do: @unknown
  def from_user_agent(""), do: @unknown

  def from_user_agent(ua) when is_binary(ua) do
    case {browser(ua), os(ua)} do
      {nil, nil} -> @unknown
      {browser, nil} -> browser
      {nil, os} -> "Browser on #{os}"
      {browser, os} -> "#{browser} on #{os}"
    end
  end

  # Order matters: Edge/OPR/Chrome all carry "Safari"/"Chrome" tokens in their own
  # UA strings, so the more specific brand must be checked first.
  defp browser(ua) do
    cond do
      ua =~ "Edg/" -> "Edge"
      ua =~ "OPR/" or ua =~ "Opera" -> "Opera"
      ua =~ "Firefox/" -> "Firefox"
      ua =~ "CriOS/" or ua =~ "Chrome/" -> "Chrome"
      ua =~ "FxiOS/" -> "Firefox"
      ua =~ "Safari/" and ua =~ "Version/" -> "Safari"
      true -> nil
    end
  end

  defp os(ua) do
    cond do
      ua =~ "iPhone" or ua =~ "iPad" or ua =~ "iPod" -> "iOS"
      ua =~ "Android" -> "Android"
      ua =~ "Mac OS X" -> "macOS"
      ua =~ "Windows" -> "Windows"
      ua =~ "CrOS" -> "ChromeOS"
      ua =~ "Linux" -> "Linux"
      true -> nil
    end
  end
end
