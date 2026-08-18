defmodule SamenAnthropic.Transport do
  @moduledoc """
  Default (real) HTTP transport for `SamenAnthropic.Provider.complete/2` — a plain
  `Req` POST to Anthropic's Messages API endpoint (`POST /v1/messages`).

  `SamenAnthropic.Provider.complete/2` accepts an injectable `config[:transport]`
  (an arity-1 function `request_map -> {:ok, response_map} | {:error, term()}`) that,
  when present, REPLACES this module — the fixture harness (and any other hermetic
  test) supplies a fake transport there so `mix test` NEVER touches the network
  (ADR-043 §4 keyless posture). This module is exercised for real ONLY on the
  operator-gated `SAMEN_AI_LIVE=1` live lane.
  """

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @doc """
  `request` is `%{api_key: String.t(), body: map(), anthropic_version: String.t()}`.
  Returns `{:ok, %{status: integer(), body: map() | binary()}}` or `{:error, reason}`
  on a transport-level failure (DNS/connect/timeout).
  """
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{api_key: api_key, body: body} = request) do
    version = Map.get(request, :anthropic_version, @anthropic_version)

    case Req.post(@endpoint,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", version},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
