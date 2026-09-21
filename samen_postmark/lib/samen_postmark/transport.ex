defmodule SamenPostmark.Transport do
  @moduledoc """
  Default (real) HTTP transport for `SamenPostmark.Provider.deliver/2` — a
  plain `Req` POST to Postmark's send-email endpoint.

  `SamenPostmark.Provider.deliver/2` accepts an injectable `config[:transport]`
  (an arity-1 function `request_map -> {:ok, response_map} | {:error, term()}`)
  that, when present, REPLACES this module — the fixture harness (and any
  other hermetic test) supplies a fake transport there so `mix test` NEVER
  touches the network (ADR-038 §7.1 lane 0). This module is exercised for
  real only by `mix samen.smoke.postmark` (§7.4, `SAMEN_POSTMARK_SMOKE=1`) and
  by the (undocumented-here, operator-gated) `SAMEN_ESP_LIVE=1` live-smoke lane.
  """

  @endpoint "https://api.postmarkapp.com/email"

  @doc """
  `request` is `%{server_token: String.t(), body: map()}`. Returns
  `{:ok, %{status: integer(), body: map() | binary(), headers: map()}}` or
  `{:error, reason}` on a transport-level failure (DNS/connect/timeout — the smoke
  task's offline-skip detection inspects this `reason`).

  `:headers` is carried (T170) so `SamenPostmark.Provider` can read `Retry-After`
  off a `429` and turn it into a `{:throttled, seconds}` snooze instead of a burned
  Oban attempt. A fake transport that omits `:headers` still works — the provider
  defaults it to `%{}` and falls back to `Samen.Delivery.Throttle.default_seconds/0`.
  """
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{server_token: token, body: body}) do
    case Req.post(@endpoint,
           json: body,
           headers: [{"X-Postmark-Server-Token", token}, {"Accept", "application/json"}]
         ) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok, %{status: status, body: resp_body, headers: resp_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
