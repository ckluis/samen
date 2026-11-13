defmodule Samen.Web.Webhook.RawBodyReaderTest do
  @moduledoc """
  The webhook body reader honors the whole `Plug.Conn.read_body/2` contract. An oversized
  unauthenticated POST must become a 413 (the parser's `RequestTooLargeError`), never a
  `MatchError` / 500; the raw-bytes cache must still work for the normal path.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias Samen.Web.Webhook.RawBodyReader

  defp parsers(length) do
    Plug.Parsers.init(
      parsers: [:json],
      pass: ["*/*"],
      length: length,
      body_reader: {RawBodyReader, :read_body, []},
      json_decoder: Jason
    )
  end

  defp post(body) do
    conn(:post, "/webhooks/x", body) |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  test "control: an in-limit JSON POST parses AND the raw bytes are cached for signature verification" do
    body = ~s({"a":1})
    conn = Plug.Parsers.call(post(body), parsers(1_000))

    assert conn.body_params == %{"a" => 1}
    assert RawBodyReader.raw_body(conn) == body
  end

  test "RED: an oversized POST is a 413 RequestTooLargeError, not a MatchError (500)" do
    body = ~s({"pad":") <> String.duplicate("x", 5_000) <> ~s("})

    error = assert_raise Plug.Parsers.RequestTooLargeError, fn -> Plug.Parsers.call(post(body), parsers(100)) end
    assert Plug.Exception.status(error) == 413
  end

  test "RED: read_body passes {:more, _, _} through and caches no partial body" do
    body = String.duplicate("y", 5_000)

    assert {:more, partial, conn} = RawBodyReader.read_body(post(body), length: 100)
    assert byte_size(partial) <= 5_000
    refute Map.has_key?(conn.assigns, :raw_webhook_body)
  end
end
