defmodule SamenResend.Transport do
  @moduledoc """
  Default (real) HTTP transport for `SamenResend.Provider.deliver/2` — a
  plain `Req` POST to Resend's send-email endpoint (`POST /emails`,
  Bearer-token auth).

  `SamenResend.Provider.deliver/2` accepts an injectable `config[:transport]`
  (an arity-1 function `request_map -> {:ok, response_map} | {:error, term()}`)
  that, when present, REPLACES this module — the fixture/conformance harness
  (and any other hermetic test) supplies a fake transport there so `mix test`
  NEVER touches the network (ADR-038 §7.1 lane 0). This module is exercised
  for real only by the operator-gated `SAMEN_ESP_LIVE=1` live-smoke lane
  (`mix samen.smoke.resend`, ADR-038 §7.1 lane 2).
  """

  @endpoint "https://api.resend.com/emails"

  @doc """
  `request` is `%{api_key: String.t(), from: String.t(), to_email: String.t(),
  subject: String.t(), text_body: String.t()}`. Returns
  `{:ok, %{status: integer(), body: map() | binary()}}` or `{:error, reason}`
  on a transport-level failure (DNS/connect/timeout — the smoke task's
  offline-skip detection inspects this `reason`).
  """
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{api_key: api_key, from: from, to_email: to_email} = request) do
    body =
      Jason.encode!(%{
        "from" => from,
        "to" => [to_email],
        "subject" => Map.get(request, :subject, "(rendering pending — template)"),
        "text" => Map.get(request, :text_body, "(rendering pending — ADR-038 C3/T29)")
      })

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.post(@endpoint, body: body, headers: headers) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def live(_request), do: {:error, :invalid_request}
end
