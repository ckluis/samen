defmodule Samen.Webhook.DeliveryWorkerSsrfStubRepo do
  @moduledoc """
  Repo double for the #25 reds. `Samen.Webhook.DeliveryWorker.load_endpoint/2` calls
  `repo.get_by(endpoint_module, id: id)`; this returns the endpoint row the test put in
  its own process dictionary. `perform/1` is called DIRECTLY from the test process, so a
  process-local table is reachable and needs no global state.
  """

  def get_by(_module, id: id) do
    Process.get(:ssrf_endpoints, %{}) |> Map.get(id)
  end
end

defmodule Samen.Webhook.DeliveryWorkerSsrfTest do
  @moduledoc """
  Issue #25 RED PATHS — `Samen.Webhook.DeliveryWorker` must refuse to POST a
  tenant-registered endpoint URL that points inside the perimeter.

  Before the fix the worker ran `load_endpoint → reveal_secret → endpoint_url →
  deliver` with NO scheme/host/private-range check, through a redirect-FOLLOWING shared
  adapter. Every test here drives the real `perform/1` with an injected adapter double
  and an injected DNS resolver, so nothing real is dialed and the assertion is "the
  adapter double recorded ZERO posts".

  The positive control — a public `https` endpoint whose stubbed resolver answers with a
  public address — must still deliver exactly once, so a red here means "the guard
  refused this target", never "delivery broke".
  """
  # NOT async: the worker reads its adapter from `Application.get_env/3`, and the guard's
  # resolver from another app-env key. Both are global.
  use ExUnit.Case, async: false

  alias Samen.Webhook.DeliveryWorker
  alias Samen.Webhook.HttpAdapter.Test, as: AdapterDouble

  @public_ip {93, 184, 216, 34}

  setup do
    prev_adapter = Application.get_env(:samen_core, :webhook_http_adapter)
    prev_guard = Application.get_env(:samen_core, Samen.Egress.Guard)

    Application.put_env(:samen_core, :webhook_http_adapter, AdapterDouble)

    Application.put_env(:samen_core, Samen.Egress.Guard,
      resolver: Samen.Egress.Guard.Resolver.Test,
      resolver_map: %{
        "hook.example.test" => @public_ip,
        # The DNS-rebinding shape: a perfectly public-looking hostname whose
        # authoritative answer is an internal address.
        "rebind.example.test" => {10, 0, 0, 5},
        # One public answer AND one private answer — ANY private answer must block.
        "split.example.test" => [@public_ip, {127, 0, 0, 1}]
      }
    )

    {:ok, double} = AdapterDouble.start_link()
    AdapterDouble.register(double)

    on_exit(fn ->
      restore(:webhook_http_adapter, prev_adapter)
      restore(Samen.Egress.Guard, prev_guard)
    end)

    {:ok, double: double}
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, value), do: Application.put_env(:samen_core, key, value)

  # Registers an endpoint row with `url` and returns the job args that deliver to it.
  defp job_args(url) do
    id = Ecto.UUID.generate()

    Process.put(
      :ssrf_endpoints,
      Map.put(Process.get(:ssrf_endpoints, %{}), id, %{
        id: id,
        url: url,
        signing_secret: "endpoint_signing_secret"
      })
    )

    %{
      "endpoint_id" => id,
      "idempotency_key" => Ecto.UUID.generate(),
      "event_type" => "invoice.created",
      "body" => ~s({"event":"invoice.created","id":"abc"}),
      "org_id" => Ecto.UUID.generate(),
      "repo" => "Samen.Webhook.DeliveryWorkerSsrfStubRepo"
    }
  end

  defp run(url), do: DeliveryWorker.perform(%Oban.Job{args: job_args(url)})

  # ---------------------------------------------------------------------------
  # RED PATHS — each target must be refused with ZERO posts recorded.

  test "#25 RED: an endpoint registered at the cloud metadata service is refused and never POSTed",
       %{double: double} do
    assert {:discard, reason} = run("http://169.254.169.254/latest/meta-data/")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == [], "the metadata service must never be POSTed"
  end

  test "#25 RED: an endpoint registered at loopback is refused and never POSTed", %{
    double: double
  } do
    assert {:discard, reason} = run("http://127.0.0.1:4000/hook")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == [], "loopback must never be POSTed"
  end

  test "#25 RED: an endpoint registered at an RFC1918 address is refused and never POSTed",
       %{double: double} do
    assert {:discard, reason} = run("http://10.0.0.1/internal/hook")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == [], "an RFC1918 target must never be POSTed"
  end

  test "#25 RED: an endpoint registered at IPv6 loopback is refused and never POSTed", %{
    double: double
  } do
    assert {:discard, reason} = run("http://[::1]:4000/hook")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == [], "IPv6 loopback must never be POSTed"
  end

  test "#25 RED: an endpoint registered at an IPv4-mapped IPv6 metadata address is refused",
       %{double: double} do
    assert {:discard, reason} = run("http://[::ffff:169.254.169.254]/latest/meta-data/")
    assert reason =~ "egress guard"

    assert AdapterDouble.calls(double) == [],
           "wrapping the metadata address in IPv6 must not launder it"
  end

  test "#25 RED: a public hostname whose resolver answers with a private address (DNS rebinding shape) is refused",
       %{double: double} do
    assert {:discard, reason} = run("https://rebind.example.test/hook")
    assert reason =~ "egress guard"

    assert AdapterDouble.calls(double) == [],
           "resolve-then-deny must refuse a public NAME with a private ANSWER"
  end

  test "#25 RED: one private answer among several blocks the URL", %{double: double} do
    assert {:discard, reason} = run("https://split.example.test/hook")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == []
  end

  test "#25 RED: an unresolvable host fails CLOSED (never a silent allow)", %{double: double} do
    assert {:discard, reason} = run("https://nowhere.example.invalid/hook")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == []
  end

  test "#25 RED: a non-http(s) scheme is refused", %{double: double} do
    assert {:discard, reason} = run("file:///etc/passwd")
    assert reason =~ "egress guard"
    assert AdapterDouble.calls(double) == []
  end

  # ---------------------------------------------------------------------------
  # Discard, not retry: a refused URL is a PERMANENT configuration fault. Retrying it
  # 20 times would be the same defect twenty times over.

  test "#25: a guard refusal is a DISCARD, not an Oban retry" do
    assert {:discard, _reason} = run("http://169.254.169.254/latest/meta-data/")
  end

  # ---------------------------------------------------------------------------
  # POSITIVE CONTROL — delivery itself still works.

  test "#25 POSITIVE CONTROL: a public https endpoint with a public-resolving host still delivers exactly once",
       %{double: double} do
    assert :ok = run("https://hook.example.test/deliver")

    assert [{url, body, headers}] = AdapterDouble.calls(double)
    assert url == "https://hook.example.test/deliver"
    assert body == ~s({"event":"invoice.created","id":"abc"})
    assert {"Content-Type", "application/json"} in headers
    assert Enum.any?(headers, fn {k, v} -> k == "Samen-Signature" and String.starts_with?(v, "t=") end)
  end

  test "#25 POSITIVE CONTROL: a real delivery failure is still a RETRY, not a discard", %{
    double: double
  } do
    AdapterDouble.set_response(double, {:error, {:http_status, 503}})

    assert {:error, {:http_status, 503}} = run("https://hook.example.test/deliver")
    assert length(AdapterDouble.calls(double)) == 1
  end

  # ---------------------------------------------------------------------------
  # Redirect: the worker must not be handed a followed hop. The adapter double answers
  # 302, which is a delivery FAILURE — exactly one POST, to the original URL, and the
  # `Location` is never dialed.

  test "#25 RED: a 302 toward a private address is a delivery failure, never a followed hop",
       %{double: double} do
    AdapterDouble.set_response(double, {:error, {:http_status, 302}})

    assert {:error, {:http_status, 302}} = run("https://hook.example.test/deliver")

    assert [{url, _body, _headers}] = AdapterDouble.calls(double)

    assert url == "https://hook.example.test/deliver",
           "the only POST must be the original URL — no redirect hop"
  end

  # ---------------------------------------------------------------------------
  # The guard runs BEFORE the signing secret is revealed: a request we will refuse has
  # no business decrypting a per-endpoint credential.

  test "#25: the guard refuses before the signing secret is revealed" do
    id = Ecto.UUID.generate()

    # A row whose secret CANNOT be revealed (no vault wired, a %Masked{} value). If the
    # guard ran after the reveal this would surface the reveal's error instead of the
    # guard's discard.
    Process.put(:ssrf_endpoints, %{
      id => %{
        id: id,
        url: "http://169.254.169.254/latest/meta-data/",
        signing_secret: %Samen.Masked{token: "vt_never_revealed", label: :signing_secret}
      }
    })

    args = %{
      "endpoint_id" => id,
      "idempotency_key" => Ecto.UUID.generate(),
      "event_type" => "invoice.created",
      "body" => "{}",
      "org_id" => Ecto.UUID.generate(),
      "repo" => "Samen.Webhook.DeliveryWorkerSsrfStubRepo"
    }

    assert {:discard, reason} = DeliveryWorker.perform(%Oban.Job{args: args})
    assert reason =~ "egress guard"
  end
end
