defmodule SamenSes.ThrottleTest do
  @moduledoc """
  T170 (bug half) RED PATHS — an SES throttle response must map to the DISTINCT
  `{:error, {:throttled, seconds}}`, not to the generic `{:ses_error, …}` that the
  delivery Oban workers hand straight back to Oban as an ordinary retry.

  SES names the condition two ways depending on API generation: SESv2 answers `429` with
  `__type: "TooManyRequestsException"`, the older query API answers `400` with
  `Throttling` / `ThrottlingException`. Both must be caught — by NAME, not only by
  status.

  Positive controls: a `500` still errors and still retries, a non-throttle `400` keeps
  its exact pre-T170 tuple, and a `2xx` still delivers.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Message
  alias SamenSes.Provider

  defp msg do
    %Message{send_id: "s1", org_id: "o1", to_subscriber_id: "sub1", template_id: nil}
  end

  defp config(response) do
    %{
      access_key_id: "AKIA_TEST",
      secret_access_key: "secret",
      region: "us-east-1",
      from: "sender@example.test"
    }
    |> Map.put(:resolve_recipient, fn _m -> {:ok, "to@example.test"} end)
    |> Map.put(:transport, fn _req -> response end)
  end

  defp deliver(response), do: Provider.deliver(msg(), config(response))

  # ---------------------------------------------------------------------------
  # RED

  test "T170 RED: an SESv2 429 TooManyRequestsException is a throttle carrying Retry-After" do
    result =
      deliver(
        {:ok,
         %{
           status: 429,
           body: %{
             "__type" => "TooManyRequestsException",
             "message" => "Maximum sending rate exceeded."
           },
           headers: %{"retry-after" => ["45"]}
         }}
      )

    assert {:error, {:throttled, 45}} = result
  end

  test "T170 RED: the older query API's 400 Throttling is a throttle too, caught by NAME" do
    result =
      deliver(
        {:ok,
         %{
           status: 400,
           body: %{"__type" => "Throttling", "message" => "Maximum sending rate exceeded."}
         }}
      )

    assert {:error, {:throttled, seconds}} = result
    assert seconds == Samen.Delivery.Throttle.default_seconds()
  end

  test "T170 RED: a fully-qualified ThrottlingException __type is a throttle" do
    result =
      deliver(
        {:ok,
         %{
           status: 400,
           body: %{
             "__type" => "com.amazonaws.ses#ThrottlingException",
             "message" => "Rate exceeded"
           },
           headers: [{"Retry-After", "10"}]
         }}
      )

    assert {:error, {:throttled, 10}} = result
  end

  # ---------------------------------------------------------------------------
  # POSITIVE CONTROLS

  test "T170 POSITIVE CONTROL: a 500 is still a plain error that Oban retries as today" do
    result =
      deliver(
        {:ok,
         %{status: 500, body: %{"__type" => "InternalFailure", "message" => "server error"}}}
      )

    assert {:error, {:ses_error, 500, "InternalFailure", "server error"}} = result
    refute match?({:error, {:throttled, _}}, result)
  end

  test "T170 POSITIVE CONTROL: a non-throttle 400 keeps its exact pre-T170 tuple" do
    result =
      deliver(
        {:ok,
         %{
           status: 400,
           body: %{"__type" => "MessageRejected", "message" => "Email address is not verified."}
         }}
      )

    assert {:error, {:ses_error, 400, "MessageRejected", "Email address is not verified."}} =
             result
  end

  test "T170 POSITIVE CONTROL: an error body with no __type keeps its pre-T170 tuple" do
    result = deliver({:ok, %{status: 403, body: %{"message" => "denied"}}})
    assert {:error, {:ses_error, 403, "SesError", "denied"}} = result
  end

  test "T170 POSITIVE CONTROL: an unexpected response body is unchanged" do
    result = deliver({:ok, %{status: 502, body: "<html>bad gateway</html>"}})
    assert {:error, {:unexpected_response, 502, "<html>bad gateway</html>"}} = result
  end

  test "T170 POSITIVE CONTROL: a 2xx still delivers" do
    result = deliver({:ok, %{status: 200, body: %{"MessageId" => "ses-id-1"}}})
    assert {:ok, %{provider_message_id: "ses-id-1"}} = result
  end

  test "T170 POSITIVE CONTROL: a transport-level failure is unchanged" do
    assert {:error, :nxdomain} = deliver({:error, :nxdomain})
  end
end
