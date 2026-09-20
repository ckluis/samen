defmodule SamenPostmark.ThrottleTest do
  @moduledoc """
  T170 (bug half) RED PATHS — a Postmark throttle response must map to the DISTINCT
  `{:error, {:throttled, seconds}}`, not to the generic `{:postmark_error, 429, …}` that
  the delivery Oban workers hand straight back to Oban as an ordinary retry.

  Before the fix `samen_postmark` had ZERO references to 429 / rate limiting, so a
  throttle was an ordinary error, Oban retried it on its exponential schedule against an
  account that had just said "too fast", and each hammer burned one of 20 attempts.

  Positive controls in this file: a `500` still errors and still retries exactly as
  before, and a `2xx` still delivers — so a red here means "the throttle is not
  recognised", never "error handling or delivery broke".
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenPostmark.Provider

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp config(response) do
    %{server_token: "tok", from: "sender@example.test"}
    |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
    |> Map.put(:transport, fn _req -> response end)
  end

  defp deliver(response), do: Provider.deliver(msg(), config(response))

  # ---------------------------------------------------------------------------
  # RED

  test "T170 RED: a Postmark 429 is a throttle carrying Retry-After, not a generic error" do
    result =
      deliver(
        {:ok,
         %{
           status: 429,
           body: %{"ErrorCode" => 429, "Message" => "You have exceeded the rate limit."},
           headers: %{"retry-after" => ["120"]}
         }}
      )

    assert {:error, {:throttled, 120}} = result
  end

  test "T170 RED: a Postmark 429 with no Retry-After header still throttles, at the default wait" do
    result = deliver({:ok, %{status: 429, body: %{"ErrorCode" => 429, "Message" => "slow down"}}})

    assert {:error, {:throttled, seconds}} = result
    assert seconds == Samen.Delivery.Throttle.default_seconds()
  end

  test "T170 RED: a body ErrorCode of 429 throttles even if a gateway rewrote the status" do
    result =
      deliver(
        {:ok,
         %{
           status: 200,
           body: %{"ErrorCode" => 429, "Message" => "rate limited"},
           headers: [{"Retry-After", "30"}]
         }}
      )

    assert {:error, {:throttled, 30}} = result
  end

  # ---------------------------------------------------------------------------
  # POSITIVE CONTROLS

  test "T170 POSITIVE CONTROL: a 500 is still a plain error that Oban retries as today" do
    result =
      deliver({:ok, %{status: 500, body: %{"ErrorCode" => 10, "Message" => "server error"}}})

    assert {:error, {:postmark_error, 500, 10, "server error"}} = result
    refute match?({:error, {:throttled, _}}, result)
  end

  test "T170 POSITIVE CONTROL: a 422 Postmark error is unchanged" do
    result =
      deliver({:ok, %{status: 422, body: %{"ErrorCode" => 300, "Message" => "invalid email"}}})

    assert {:error, {:postmark_error, 422, 300, "invalid email"}} = result
  end

  test "T170 POSITIVE CONTROL: a 2xx still delivers" do
    result =
      deliver({:ok, %{status: 200, body: %{"MessageID" => "real-id-1", "ErrorCode" => 0}}})

    assert {:ok, %{provider_message_id: "real-id-1"}} = result
  end

  test "T170 POSITIVE CONTROL: a transport-level failure is unchanged" do
    assert {:error, :econnrefused} = deliver({:error, :econnrefused})
  end
end
