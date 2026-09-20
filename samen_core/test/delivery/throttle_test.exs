defmodule Samen.Delivery.ThrottleTest do
  @moduledoc """
  T170 (bug half) — `Samen.Delivery.Throttle`'s own matrix: header shapes, the
  `Retry-After` forms, the clamp, and the Oban translation.

  The three adapter test files prove each vendor's throttle response is RECOGNISED;
  `Samen.Delivery.ThrottleSnoozeTest` proves the workers SNOOZE on it. This file proves
  the wait is derived correctly.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.Throttle

  describe "retry_after_seconds/1 — header shapes" do
    test "T170: reads Retry-After from Req's map-of-lists shape" do
      assert Throttle.retry_after_seconds(%{"retry-after" => ["120"]}) == 120
    end

    test "T170: reads Retry-After from a list of {name, value} tuples, case-insensitively" do
      assert Throttle.retry_after_seconds([{"Retry-After", "45"}]) == 45
    end

    test "T170: reads a charlist header name and value (the :httpc shape)" do
      assert Throttle.retry_after_seconds([{~c"retry-after", ~c"30"}]) == 30
    end

    test "T170: falls back to ratelimit-reset / x-ratelimit-reset when Retry-After is absent" do
      assert Throttle.retry_after_seconds(%{"ratelimit-reset" => ["7"]}) == 7
      assert Throttle.retry_after_seconds(%{"x-ratelimit-reset" => ["9"]}) == 9
    end

    test "T170: Retry-After WINS over ratelimit-reset when both are present" do
      headers = %{"retry-after" => ["20"], "ratelimit-reset" => ["300"]}
      assert Throttle.retry_after_seconds(headers) == 20
    end

    test "T170 POSITIVE CONTROL: no headers, an unusable value, or a junk shape all default" do
      default = Throttle.default_seconds()

      assert Throttle.retry_after_seconds(%{}) == default
      assert Throttle.retry_after_seconds([]) == default
      assert Throttle.retry_after_seconds(nil) == default
      assert Throttle.retry_after_seconds(:not_headers) == default
      assert Throttle.retry_after_seconds(%{"retry-after" => ["not-a-number"]}) == default
      assert Throttle.retry_after_seconds([{"retry-after", nil}]) == default
    end
  end

  describe "retry_after_seconds/1 — the HTTP-date form" do
    test "T170: an RFC 1123 date becomes seconds-from-now" do
      at = DateTime.utc_now() |> DateTime.add(90, :second)

      header =
        at
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      seconds = Throttle.retry_after_seconds(%{"retry-after" => [header]})
      assert_in_delta seconds, 90, 5
    end

    test "T170: a date already in the past clamps to the 1s floor, never a negative snooze" do
      at = DateTime.utc_now() |> DateTime.add(-600, :second)
      header = Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")

      assert Throttle.retry_after_seconds(%{"retry-after" => [header]}) == 1
    end
  end

  describe "retry_after_seconds/1 — the clamp" do
    test "T170: a 0 or negative Retry-After lifts to 1s — a 0 would reproduce the storm" do
      assert Throttle.retry_after_seconds(%{"retry-after" => ["0"]}) == 1
      assert Throttle.retry_after_seconds(%{"retry-after" => ["-5"]}) == 1
    end

    test "T170: an absurd Retry-After caps at 3600s — a job must not park for days" do
      assert Throttle.retry_after_seconds(%{"retry-after" => ["999999"]}) == 3600
    end

    test "T170 POSITIVE CONTROL: a sane value inside the range is passed through exactly" do
      assert Throttle.retry_after_seconds(%{"retry-after" => ["1"]}) == 1
      assert Throttle.retry_after_seconds(%{"retry-after" => ["600"]}) == 600
      assert Throttle.retry_after_seconds(%{"retry-after" => ["3600"]}) == 3600
    end
  end

  describe "throttled/1 and oban_result/1" do
    test "T170: throttled/1 builds the distinct error tuple with the derived wait" do
      assert {:error, {:throttled, 120}} = Throttle.throttled(%{"retry-after" => ["120"]})
    end

    test "T170: throttled?/1 recognises only the throttle tuple" do
      assert Throttle.throttled?({:error, {:throttled, 30}})
      refute Throttle.throttled?({:error, {:http_status, 429}})
      refute Throttle.throttled?({:error, {:throttled, 0}})
      refute Throttle.throttled?({:ok, %{}})
    end

    test "T170: oban_result/1 turns a throttle into {:snooze, seconds}" do
      assert {:snooze, 90} = Throttle.oban_result({:error, {:throttled, 90}})
    end

    test "T170 POSITIVE CONTROL: oban_result/1 leaves every other result alone" do
      assert :no_throttle = Throttle.oban_result({:error, {:http_status, 500}})
      assert :no_throttle = Throttle.oban_result({:error, :adapter_unconfigured})
      assert :no_throttle = Throttle.oban_result({:ok, %{provider_message_id: "x"}})
    end
  end
end
