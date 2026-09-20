defmodule SamenResend.ThrottleTest do
  @moduledoc """
  T170 (bug half) RED PATHS — a Resend throttle response must map to the DISTINCT
  `{:error, {:throttled, seconds}}`, not to the generic `{:resend_error, …}` that the
  delivery Oban workers hand straight back to Oban as an ordinary retry.

  Resend answers `429` and names the condition in the body's `name`:
  `rate_limit_exceeded` (the per-second limit) or `daily_quota_exceeded`. Both must be
  caught — by NAME as well as by status — and the wait prefers Resend's
  `ratelimit-reset` header when `Retry-After` is absent.

  Positive controls: a `500` still errors and still retries, a non-throttle `422` keeps
  its exact pre-T170 tuple, and a `2xx` still delivers.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenResend.Provider

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp config(response) do
    %{api_key: "re_test", from: "sender@example.test"}
    |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
    |> Map.put(:transport, fn _req -> response end)
  end

  defp deliver(response), do: Provider.deliver(msg(), config(response))

  # ---------------------------------------------------------------------------
  # RED

  test "T170 RED: a Resend 429 rate_limit_exceeded is a throttle carrying Retry-After" do
    result =
      deliver(
        {:ok,
         %{
           status: 429,
           body: %{
             "name" => "rate_limit_exceeded",
             "message" => "Too many requests. Please limit to 2 requests per second."
           },
           headers: %{"retry-after" => ["1"]}
         }}
      )

    assert {:error, {:throttled, 1}} = result
  end

  test "T170 RED: daily_quota_exceeded is a throttle too, caught by NAME" do
    result =
      deliver(
        {:ok,
         %{
           status: 429,
           body: %{"name" => "daily_quota_exceeded", "message" => "Daily quota reached."}
         }}
      )

    assert {:error, {:throttled, seconds}} = result
    assert seconds == Samen.Delivery.Throttle.default_seconds()
  end

  test "T170 RED: ratelimit-reset is used when Retry-After is absent" do
    result =
      deliver(
        {:ok,
         %{
           status: 429,
           body: %{"name" => "rate_limit_exceeded", "message" => "slow down"},
           headers: %{"ratelimit-reset" => ["7"]}
         }}
      )

    assert {:error, {:throttled, 7}} = result
  end

  test "T170 RED: the throttle NAME is caught even if a gateway rewrote the status" do
    result =
      deliver(
        {:ok,
         %{
           status: 200,
           body: %{"name" => "rate_limit_exceeded", "message" => "slow down"},
           headers: [{"retry-after", "5"}]
         }}
      )

    assert {:error, {:throttled, 5}} = result
  end

  # ---------------------------------------------------------------------------
  # POSITIVE CONTROLS

  test "T170 POSITIVE CONTROL: a 500 is still a plain error that Oban retries as today" do
    result =
      deliver(
        {:ok,
         %{status: 500, body: %{"name" => "internal_server_error", "message" => "server error"}}}
      )

    assert {:error, {:resend_error, 500, "internal_server_error", "server error"}} = result
    refute match?({:error, {:throttled, _}}, result)
  end

  test "T170 POSITIVE CONTROL: a non-throttle 422 keeps its exact pre-T170 tuple" do
    result =
      deliver(
        {:ok,
         %{
           status: 422,
           body: %{"name" => "validation_error", "message" => "The from address is invalid."}
         }}
      )

    assert {:error, {:resend_error, 422, "validation_error", "The from address is invalid."}} =
             result
  end

  test "T170 POSITIVE CONTROL: an unexpected response body is unchanged" do
    result = deliver({:ok, %{status: 502, body: "<html>bad gateway</html>"}})
    assert {:error, {:unexpected_response, 502, "<html>bad gateway</html>"}} = result
  end

  test "T170 POSITIVE CONTROL: a 2xx still delivers" do
    result = deliver({:ok, %{status: 200, body: %{"id" => "resend-id-1"}}})
    assert {:ok, %{provider_message_id: "resend-id-1"}} = result
  end

  test "T170 POSITIVE CONTROL: a transport-level failure is unchanged" do
    assert {:error, :timeout} = deliver({:error, :timeout})
  end
end
