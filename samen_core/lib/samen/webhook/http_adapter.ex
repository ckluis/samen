defmodule Samen.Webhook.HttpAdapter do
  @moduledoc """
  Behaviour for the webhook HTTP delivery adapter.

  The delivery worker calls `adapter.post/3` to dispatch the HTTP request. This
  abstraction lets tests inject a stubbed adapter (capturing calls, returning
  configurable responses) without hitting a real network.

  ## Production adapter

  `Samen.Webhook.HttpAdapter.Httpc` — uses Erlang's built-in `:httpc`. No
  additional dependency required; suitable for reasonable webhook volumes. A host
  may configure `Req` or `Finch` by setting:

      config :samen_core, :webhook_http_adapter, MyApp.Webhook.FinchAdapter

  ## Test adapter

  `Samen.Webhook.HttpAdapter.Test` — captures calls to an agent for assertion.
  """

  @doc """
  POST `body` to `url` with the given `headers`.

  Returns `{:ok, status_code}` on HTTP 2xx, or `{:error, reason}` otherwise.
  A non-2xx status code is an `{:error, {:http_status, code}}`.
  """
  @callback post(url :: String.t(), body :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, non_neg_integer()} | {:error, term()}
end

defmodule Samen.Webhook.HttpAdapter.Httpc do
  @moduledoc """
  Production HTTP adapter using Erlang's built-in `:httpc`.
  """

  @behaviour Samen.Webhook.HttpAdapter

  @impl true
  def post(url, body, headers) do
    url_charlist = String.to_charlist(url)

    headers_charlist =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    body_charlist = body

    case :httpc.request(
           :post,
           {url_charlist, headers_charlist, ~c"application/json", body_charlist},
           [{:timeout, 10_000}],
           []
         ) do
      {:ok, {{_, status, _}, _resp_headers, _body}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_, status, _}, _resp_headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Samen.Webhook.HttpAdapter.Test do
  @moduledoc """
  Test HTTP adapter — captures POST calls in an agent for assertion.

  Usage in tests:

      {:ok, adapter} = Samen.Webhook.HttpAdapter.Test.start_link()
      # configure DeliveryWorker to use this adapter (via args["adapter"])
      # ... run the job ...
      calls = Samen.Webhook.HttpAdapter.Test.calls(adapter)
      assert length(calls) == 1
      [{url, body, headers}] = calls
      assert url =~ "example.com"

  The default response is `{:ok, 200}`. Configure per-test:

      Samen.Webhook.HttpAdapter.Test.set_response(adapter, {:error, {:http_status, 503}})
  """

  @behaviour Samen.Webhook.HttpAdapter

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{calls: [], response: {:ok, 200}} end, opts)
  end

  @impl true
  def post(url, body, headers) do
    # Look up the per-process test agent registered under the calling process.
    pid = Process.get(__MODULE__)

    if pid && Process.alive?(pid) do
      Agent.get_and_update(pid, fn state ->
        call = {url, body, headers}
        new_state = %{state | calls: state.calls ++ [call]}
        {state.response, new_state}
      end)
    else
      {:ok, 200}
    end
  end

  @doc "Return the list of `{url, body, headers}` tuples captured so far."
  def calls(pid), do: Agent.get(pid, fn s -> s.calls end)

  @doc "Set the response returned by the next `post/3` call."
  def set_response(pid, response), do: Agent.update(pid, fn s -> %{s | response: response} end)

  @doc "Register this agent as the test adapter for the calling process."
  def register(pid), do: Process.put(__MODULE__, pid)
end
