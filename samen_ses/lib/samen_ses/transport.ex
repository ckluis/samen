defmodule SamenSes.Transport do
  @moduledoc """
  Default (real) HTTP transport for `SamenSes.Provider.deliver/2` — a SigV4-
  signed `Req` POST to the SESv2 `SendEmail` REST endpoint
  (`POST /v2/email/outbound-emails`).

  `SamenSes.Provider.deliver/2` accepts an injectable `config[:transport]` (an
  arity-1 function `request_map -> {:ok, response_map} | {:error, term()}`)
  that, when present, REPLACES this module — the fixture/conformance harness
  (and any other hermetic test) supplies a fake transport there so `mix test`
  NEVER touches the network (ADR-038 §7.1 lane 0). This module is exercised
  for real only by the operator-gated `SAMEN_ESP_LIVE=1` live-smoke lane
  (`mix samen.smoke.ses`, ADR-038 §7.1 lane 2).
  """

  @doc """
  `request` is `%{access_key_id:, secret_access_key:, region:, from:,
  to_email:, subject:, text_body:, session_token: (optional)}`. Returns
  `{:ok, %{status: integer(), body: map() | binary()}}` or `{:error, reason}`
  on a transport-level failure.
  """
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: region,
        from: from,
        to_email: to_email
      } = request) do
    host = "email.#{region}.amazonaws.com"
    url = "https://#{host}/v2/email/outbound-emails"

    body =
      Jason.encode!(%{
        "FromEmailAddress" => from,
        "Destination" => %{"ToAddresses" => [to_email]},
        "Content" => %{
          "Simple" => %{
            "Subject" => %{"Data" => Map.get(request, :subject, "(rendering pending — template)")},
            "Body" => %{
              "Text" => %{"Data" => Map.get(request, :text_body, "(rendering pending — ADR-038 C3/T29)")}
            }
          }
        }
      })

    base_headers = [{"content-type", "application/json"}, {"host", host}]

    headers =
      base_headers
      |> maybe_add_session_token(Map.get(request, :session_token))

    signed_headers =
      :aws_signature.sign_v4(
        access_key_id,
        secret_access_key,
        region,
        "ses",
        :calendar.universal_time(),
        "POST",
        url,
        headers,
        body
      )

    case Req.post(url, body: body, headers: signed_headers) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def live(_request), do: {:error, :invalid_request}

  defp maybe_add_session_token(headers, nil), do: headers
  defp maybe_add_session_token(headers, token), do: headers ++ [{"x-amz-security-token", token}]
end
