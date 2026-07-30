defmodule Samen.Automation.Actions.Webhook do
  @moduledoc """
  ADR-039 §5.2 #7 / §5.3 — `webhook`: THE leak surface (ADR-039 §11 — "webhook
  snapshot assert (no plaintext, no `vt_*`)"; the payload builder is the named
  sabotage target). Fixed, non-PII-by-construction payload schema:

      {"delivery_id": "...", "org_id": "...", "workflow_id": "...",
       "event": "updated", "subject_ref": "samen:crm.opportunity:<id>",
       "occurred_at": "...", "data": {only §4.4-eligible attrs in `include`}}

  `data` is built EXCLUSIVELY by reading `ctx.subject` — the
  `Samen.Automation.RunWorker` eligible-only projection (ADR-039 §4.4 read-side
  twin). A vault field is not merely FILTERED here — it structurally never
  reaches this module's memory in the first place, because `ctx.subject` never
  carries it. `include` names WHICH eligible attributes to expose (a subset);
  even a config that (incorrectly) names an ineligible one yields nothing for
  that key — `ctx.subject` simply has no such entry to serve.

  ## Signing (§5.3)

  HMAC-SHA256 via `Samen.Webhook.Signer` — the SAME `Samen-Signature:
  t=...,v1=...` scheme the B9 outbound-webhook subsystem already ships
  (reused, not reinvented — house CLAUDE.md "framework-first"). The
  per-workflow secret travels via `ctx.webhook_secret` (populated by
  `Samen.Automation.RunWorker` from the Workflow row; never logged, never
  placed in any outcome meta, excluded from every projection by the column's
  own `public?: false`).

  ## SSRF guard (§5.3)

  `ssrf_check/1` resolves the URL's hostname and REFUSES loopback, RFC1918, and
  link-local targets; outside `:dev`/`:test` the scheme must be `https`. No
  redirect following: the production adapter
  (`Samen.Automation.Actions.WebhookHttpAdapter.Httpc`) explicitly disables
  `:autoredirect` — the SHARED `Samen.Webhook.HttpAdapter.Httpc` (a different
  subsystem, B9's outbound webhook endpoints) does not set this, so a dedicated
  adapter is used here rather than silently changing that module's behavior for
  its own callers.

  ## Idempotency (§4.6 / §5.3)

  `delivery_id` is a stable `sha256(workflow_id <> ":" <> event_id)` (falling
  back to `subject_ref` when no `event_id` — a manual/schedule trigger) — the
  SAME value across Oban retries of the same run, so a receiver dedupes a
  redelivered attempt on it (at-least-once, receiver-side dedupe, ADR-039 §4.6).
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Context
  alias Samen.Webhook.Signer

  @compiled_env Mix.env()

  @impl true
  def kind, do: :webhook

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    url = config["url"]
    include = config["include"] || []

    cond do
      not is_binary(url) or url == "" or not valid_url_shape?(url) ->
        {:error, :invalid_url}

      not is_list(include) or not Enum.all?(include, &is_binary/1) ->
        {:error, :invalid_include}

      true ->
        {:ok, %{"url" => url, "include" => include}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    url = config["url"]
    include = config["include"] || []

    with :ok <- ssrf_check(url),
         {:ok, secret} <- webhook_secret(ctx) do
      body = build_payload(ctx, include) |> Jason.encode!()
      timestamp = System.os_time(:second)
      signature = Signer.sign(body, timestamp, secret)

      headers = [{"Content-Type", "application/json"}, {"Samen-Signature", signature}]

      case adapter().post(url, body, headers) do
        {:ok, status} -> {:ok, %{kind: :webhook, status: :delivered, http_status: status}}
        {:error, reason} -> {:error, error_kind(reason)}
      end
    end
  end

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

  @doc """
  Build the fixed §5.3 payload map (pre-JSON-encoding) — exposed for the T40 c2
  snapshot assert (a direct call, no HTTP/signing needed to prove the shape).
  """
  @spec build_payload(Context.t(), [String.t()]) :: map()
  def build_payload(%Context{} = ctx, include) do
    %{
      "delivery_id" => delivery_id(ctx),
      "org_id" => ctx.org_id,
      "workflow_id" => ctx.workflow_id,
      "event" => to_string(ctx.event || "manual"),
      "subject_ref" => ctx.subject_ref,
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => data(ctx.subject, include)
    }
  end

  # ONLY reads ctx.subject (the eligible-only projection) — never a raw record
  # fetch. This is the structural guarantee: even a sabotaged `include` list
  # naming a vaulted attribute finds nothing here to serve.
  defp data(subject, include) do
    subject = subject || %{}

    Enum.reduce(include, %{}, fn name, acc ->
      key = safe_atom(name)

      value =
        cond do
          not is_nil(key) and Map.has_key?(subject, key) -> Map.get(subject, key)
          Map.has_key?(subject, name) -> Map.get(subject, name)
          true -> nil
        end

      if is_nil(value), do: acc, else: Map.put(acc, name, serialize(value))
    end)
  end

  defp serialize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp serialize(v), do: v

  defp delivery_id(%Context{workflow_id: wid, event_id: eid, subject_ref: sref}) do
    basis = to_string(wid) <> ":" <> to_string(eid || sref || "")
    :crypto.hash(:sha256, basis) |> Base.encode16(case: :lower)
  end

  defp webhook_secret(%Context{webhook_secret: secret}) when is_binary(secret) and secret != "",
    do: {:ok, secret}

  defp webhook_secret(_ctx), do: {:error, :no_webhook_secret}

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # SSRF guard (§5.3): https-only outside dev/test, resolve-then-deny
  # loopback/RFC1918/link-local. dev/test are both non-production sandboxes —
  # neither ever fronts a real tenant secret over plaintext HTTP in prod.

  defp ssrf_check(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        with :ok <- check_scheme(scheme), do: check_host(host)

      _other ->
        {:error, :invalid_url}
    end
  end

  defp check_scheme("https"), do: :ok
  defp check_scheme("http"), do: if(env() in [:dev, :test], do: :ok, else: {:error, :https_required})
  defp check_scheme(_other), do: {:error, :invalid_scheme}

  defp check_host(host) do
    case resolver().resolve(host) do
      {:ok, ip} -> if private_ip?(ip), do: {:error, :ssrf_blocked}, else: :ok
      {:error, _reason} -> {:error, :ssrf_blocked}
    end
  end

  defp resolver do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:resolver, Samen.Automation.Actions.Webhook.Resolver.Inet)
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0}), do: true
  defp private_ip?(_other), do: false

  defp valid_url_shape?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp env, do: Application.get_env(:samen_core, :automation_env, @compiled_env)

  defp adapter do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:http_adapter, Samen.Automation.Actions.WebhookHttpAdapter.Httpc)
  end

  defp error_kind({:http_status, code}), do: :"http_#{code}"
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_other), do: :delivery_failed
end

defmodule Samen.Automation.Actions.Webhook.Resolver do
  @moduledoc """
  DNS-resolution seam for the `webhook` action's SSRF guard (§5.3
  "resolve-then-deny loopback/RFC1918/link-local"). Injectable so tests can
  prove BOTH branches (allow a public-looking target, deny a private one)
  without depending on real network DNS — CI sandboxes commonly have no
  egress, and a real hostname resolving to a stable non-private IP is not a
  hermetic test fixture. Production default: `Inet` (real `:inet.getaddr/2`) —
  the guard is fail-closed by construction; the `Test` resolver is opt-in only
  via explicit config, never a silent default.
  """
  @callback resolve(host :: String.t()) :: {:ok, :inet.ip_address()} | {:error, term()}
end

defmodule Samen.Automation.Actions.Webhook.Resolver.Inet do
  @moduledoc "Production resolver — real `:inet.getaddr/2` (IPv4)."
  @behaviour Samen.Automation.Actions.Webhook.Resolver

  @impl true
  def resolve(host), do: :inet.getaddr(String.to_charlist(host), :inet)
end

defmodule Samen.Automation.Actions.Webhook.Resolver.Test do
  @moduledoc """
  Test resolver — a fixed hostname -> ip map configured via

      config :samen_core, Samen.Automation.Actions.Webhook,
        resolver: Samen.Automation.Actions.Webhook.Resolver.Test,
        resolver_map: %{"webhook.example.test" => {93, 184, 216, 34}}

  An unmapped host resolves `{:error, :nxdomain}` — fail-closed like a real
  resolver on a bogus name, never a silent allow.
  """
  @behaviour Samen.Automation.Actions.Webhook.Resolver

  @impl true
  def resolve(host) do
    map =
      Application.get_env(:samen_core, Samen.Automation.Actions.Webhook, [])
      |> Keyword.get(:resolver_map, %{})

    case Map.get(map, host) do
      nil -> {:error, :nxdomain}
      ip -> {:ok, ip}
    end
  end
end

defmodule Samen.Automation.Actions.WebhookHttpAdapter.Httpc do
  @moduledoc """
  Production HTTP adapter for the automation `webhook` action — implements the
  SAME `Samen.Webhook.HttpAdapter` behaviour the B9 outbound-webhook subsystem
  defines (so its `Test` double is reusable here too), but its OWN production
  impl: `:autoredirect` is explicitly disabled (ADR-039 §5.3 "no redirect
  following"). The shared `Samen.Webhook.HttpAdapter.Httpc` does not set this
  flag, so a dedicated module is used rather than changing that one's behavior
  for its own (different) callers.
  """

  @behaviour Samen.Webhook.HttpAdapter

  @impl true
  def post(url, body, headers) do
    headers_charlist =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers_charlist, ~c"application/json", body},
           [{:timeout, 10_000}, {:autoredirect, false}],
           []
         ) do
      {:ok, {{_line, status, _reason}, _headers, _body}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_line, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Samen.Automation.Actions.WebhookHttpAdapter.Test do
  @moduledoc """
  Test HTTP adapter for the automation `webhook` action — NAME-registered (an
  `Agent` started with a fixed module name), NOT process-dictionary-based like
  the shared `Samen.Webhook.HttpAdapter.Test`. The `webhook` action fires from
  inside an Oban job/RunWorker, a DIFFERENT process than the test process that
  configured it, so capture must be reachable by name.

      {:ok, _pid} = Samen.Automation.Actions.WebhookHttpAdapter.Test.start_link()
      # ... drain the pipeline ...
      calls = Samen.Automation.Actions.WebhookHttpAdapter.Test.calls()
      [{url, body, headers}] = calls
  """

  @behaviour Samen.Webhook.HttpAdapter

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{calls: [], response: {:ok, 200}} end, name: __MODULE__)
  end

  def stop do
    if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    :ok
  end

  @impl true
  def post(url, body, headers) do
    if Process.whereis(__MODULE__) do
      Agent.get_and_update(__MODULE__, fn state ->
        {state.response, %{state | calls: state.calls ++ [{url, body, headers}]}}
      end)
    else
      {:ok, 200}
    end
  end

  @doc "Return the `{url, body, headers}` tuples captured so far."
  def calls do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1.calls), else: []
  end

  @doc "Set the response returned by the next `post/3` call."
  def set_response(response), do: Agent.update(__MODULE__, &%{&1 | response: response})
end
