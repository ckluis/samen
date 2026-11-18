defmodule Samen.Web.Api.KeyCheckUnavailable do
  @moduledoc """
  The answer to an API request whose bearer key COULD NOT BE CHECKED (the key lookup itself failed: the read
  errored, the database is down), as opposed to a key that was checked and is wrong.

  A key that is not found, wrong or revoked is the client's problem (401 / no actor). A lookup that failed is ours:
  answering it as "bad credential" makes a correctly-authenticated client discard or rotate a good key, and makes
  monitoring read an outage as an auth problem. So this is `503 Service Unavailable` with `Retry-After`, the request
  is HALTED (fail closed: it is never served and never reaches the router as an actor-less request), and the body
  carries one JSON:API error object that names neither the key nor its prefix nor its digest.

  The caller reports the failure once (`Samen.Web.Reads.Guard.report/3`, a read) BEFORE calling `send/1`; this module
  only frames the response.
  """

  import Plug.Conn

  @retry_after_seconds 5

  @doc "The `Retry-After` value (seconds) the 503 carries."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: @retry_after_seconds

  @doc "Send the 503 and halt the pipeline."
  @spec send(Plug.Conn.t()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn) do
    body =
      Jason.encode!(%{
        "errors" => [
          %{
            "status" => "503",
            "code" => "service_unavailable",
            "title" => "Service Unavailable",
            "detail" => "The credential could not be checked right now. It was not judged invalid: retry shortly."
          }
        ],
        "jsonapi" => %{"version" => "1.0"}
      })

    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(503, body)
    |> halt()
  end
end
