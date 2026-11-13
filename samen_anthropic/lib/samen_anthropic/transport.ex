defmodule SamenAnthropic.Transport do
  @moduledoc """
  Default (real) HTTP transport for `SamenAnthropic.Provider.complete/2` — ONE `Req` POST to
  Anthropic's Messages API endpoint (`POST /v1/messages`).

  `SamenAnthropic.Provider.complete/2` accepts an injectable `config[:transport]`
  (an arity-1 function `request_map -> {:ok, response_map} | {:error, term()}`) that,
  when present, REPLACES this module — the fixture harness (and any other hermetic
  test) supplies a fake transport there so `mix test` NEVER touches the network
  (ADR-043 §4 keyless posture). This module is exercised for real ONLY on the
  operator-gated `SAMEN_AI_LIVE=1` live lane.

  ## Timeouts are explicit (2026-11-13; AX-9)

  Req's own default receive timeout is 15 s — shorter than many real completions — so the
  timeouts are set on every request from the request map the provider builds (and the
  provider takes them from its config): `:connect_timeout` (default 10 s), `:receive_timeout`
  (default 300 s) and `:request_timeout` (the whole response; Finch's, best effort on HTTP/1).
  The provider caps all three to what is left of the CALL's budget (`SamenAnthropic.Retry`),
  so one attempt cannot outlast it — and it is the budget, not these per-attempt defaults,
  that keeps a call below the agent loop's in-flight watchdog.

  Req's built-in retry is OFF here (`retry: false`): retrying is the provider's
  `SamenAnthropic.Retry` policy, which wraps whichever transport is in use — this one or a
  test's — so the policy is the same code in both and is provable without a network.
  """

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2026-10-21"
  @connect_timeout 10_000
  @receive_timeout 300_000

  @doc """
  `request` is `%{api_key:, body:, anthropic_version:, connect_timeout:, receive_timeout:,
  request_timeout:, betas:}` (all but `:api_key` and `:body` optional). Returns
  `{:ok, %{status: integer(), body: map() | binary(), headers: map()}}` or `{:error, reason}`
  on a transport-level failure (DNS/connect/timeout).
  """
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{api_key: _, body: _} = request) do
    case Req.post(@endpoint, req_options(request)) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: headers}} ->
        {:ok, %{status: status, body: resp_body, headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The exact `Req` options one request is sent with — public so the timeouts, the disabled
  Req-level retry and the headers are asserted directly rather than inferred.
  """
  @spec req_options(map()) :: keyword()
  def req_options(%{api_key: api_key, body: body} = request) do
    version = Map.get(request, :anthropic_version) || @anthropic_version

    beta_headers =
      case Map.get(request, :betas, []) do
        [_ | _] = betas -> [{"anthropic-beta", Enum.join(betas, ",")}]
        _ -> []
      end

    [
      json: body,
      headers:
        [
          {"x-api-key", api_key},
          {"anthropic-version", version},
          {"content-type", "application/json"}
        ] ++ beta_headers,
      connect_options: [timeout: Map.get(request, :connect_timeout) || @connect_timeout],
      receive_timeout: Map.get(request, :receive_timeout) || @receive_timeout,
      request_timeout: Map.get(request, :request_timeout) || :infinity,
      retry: false
    ]
  end

  @doc "The default connect timeout (ms) of one attempt."
  @spec default_connect_timeout() :: pos_integer()
  def default_connect_timeout, do: @connect_timeout

  @doc "The default receive timeout (ms) of one attempt — also the default call budget."
  @spec default_receive_timeout() :: pos_integer()
  def default_receive_timeout, do: @receive_timeout
end
