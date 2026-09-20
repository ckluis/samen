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

  ## No redirect following (issue #25)

  `:autoredirect` is explicitly `false`. httpc's DEFAULT is to follow redirects, and
  this adapter is reached with a TENANT-SUPPLIED URL (`Samen.Webhook.DeliveryWorker`
  delivers the org-registered `webhook🔒` endpoint row), so following a redirect
  let an apparently-public URL 302-pivot to `169.254.169.254` or loopback AFTER
  `Samen.Egress.Guard` had cleared the original host. A 3xx is now a delivery failure
  (`{:error, {:http_status, 302}}`) that Oban retries, not a followed hop.

  This module's moduledoc used to justify leaving the flag unset on the grounds that
  changing it "would change behaviour for its own callers". Enumerating them at #25
  found exactly one lib caller — `Samen.Webhook.DeliveryWorker` — so there were no
  other callers behind that concern. A host that substitutes its own adapter via
  `config :samen_core, :webhook_http_adapter` owns its own redirect posture; the
  `Samen.Egress.Guard` check in the worker runs regardless of which adapter is wired.

  ## Layer 3 (pinned-IP connect) is NOT implemented here — honestly named

  A DNS-rebinding TOCTOU remains: `Samen.Egress.Guard.check/2` resolves the hostname,
  and then `:httpc` resolves it AGAIN at connect time. An attacker controlling the
  authoritative DNS for their own registered hostname can answer public on the first
  lookup and private on the second.

  Closing it means connecting to the *pinned* address the guard checked while still
  presenting the original `Host` header and TLS SNI. `:httpc` has no option for that.
  The only way to approximate it is to rewrite the request URI's host to the literal IP
  and then hand `:httpc` an `{:ssl, opts}` http_option carrying
  `server_name_indication` plus a `customize_hostname_check` match_fun for the real
  hostname — and because that option REPLACES httpc's whole TLS option list, it would
  make this module responsible for reconstructing `verify_peer`, the CA store and the
  protocol versions by hand. Getting that subtly wrong silently downgrades certificate
  verification, which is a worse defect than the TOCTOU it closes. So it is deliberately
  NOT done here and NOT faked: layers 1-2 (scheme + resolve-then-deny) and no-redirect
  remove the bulk of the exposure; pinned-IP connect is a named follow-up that wants a
  client which supports it (Finch/Mint expose the connect address directly) rather than
  a hand-rolled httpc TLS option list.
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
           # `:autoredirect` OFF (issue #25) — see the moduledoc. A tenant-supplied URL
           # must not be able to 302 past the egress guard.
           [{:timeout, 10_000}, {:autoredirect, false}],
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
