defmodule Samen.Egress.Guard do
  @moduledoc """
  `Samen.Egress.Guard` — the SHARED outbound-HTTP SSRF guard (issue #25 / backlog
  `T161` §5.3). One guard, two callers: the automation `webhook` action
  (`Samen.Automation.Actions.Webhook`) and the B9 outbound-webhook delivery worker
  (`Samen.Webhook.DeliveryWorker`).

  Before #25 only the automation action was guarded; the delivery worker POSTed the
  org-registered endpoint URL verbatim through a redirect-following adapter. Any tenant
  that could register a webhook endpoint could make the platform issue signed POSTs to
  cloud instance metadata (`169.254.169.254`), loopback, or RFC1918. This module is the
  extraction of the action's guard so BOTH egress surfaces share one implementation and
  cannot drift.

  ## The two entry points

    * `check/2` — the **delivery-time authority**. Scheme check, then
      *resolve-then-deny*: the hostname is resolved through the injectable resolver and
      every address it answers with is tested against `private_ip?/1`. An unresolvable
      host is `{:error, :ssrf_blocked}` — **fail closed**, never a silent allow.
    * `check_literal/2` — the **registration-time** check. The SAME scheme check plus
      `private_ip?/1` applied only when the host is already an IP *literal*. It performs
      NO DNS, so it is safe on a write path and cannot be defeated by a slow resolver.
      It is deliberately weaker: a hostname that resolves privately passes here and is
      caught at delivery time. DNS changes between registration and delivery, so
      registration can never be the authority — it only stops the obvious case from
      being persisted at all.

  Both return `:ok` or `{:error, reason}` where reason is one of `:invalid_url`,
  `:invalid_scheme`, `:https_required`, `:ssrf_blocked`.

  ## What `private_ip?/1` denies

  IPv4: `0.0.0.0/8` (this-host), `10.0.0.0/8`, `100.64.0.0/10` (CGNAT), `127.0.0.0/8`
  (loopback), `169.254.0.0/16` (**link-local — the cloud instance-metadata service**),
  `172.16.0.0/12`, `192.0.0.0/24` (IETF protocol assignments), `192.168.0.0/16`,
  `198.18.0.0/15` (benchmarking), `224.0.0.0/4` (multicast), `240.0.0.0/4` (reserved).

  IPv6: `::` (unspecified), `::1` (loopback), `fc00::/7` (unique-local), `fe80::/10`
  (link-local), `ff00::/8` (multicast) — plus the two **IPv4-in-IPv6 forms**, which are
  unwrapped and re-tested as IPv4 rather than waved through: IPv4-mapped
  (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`). Without that unwrap
  `http://[::ffff:169.254.169.254]/` would reach the metadata service through a guard
  that "covers IPv6".

  ## Scheme

  `https` always passes. `http` passes ONLY in `:dev`/`:test` (both non-production
  sandboxes — neither ever fronts a real tenant secret over plaintext HTTP in prod);
  elsewhere it is `{:error, :https_required}`. Every other scheme — `file:`, `gopher:`,
  `javascript:` — is `{:error, :invalid_scheme}`.

  ## Injectable resolver

  The resolver is a seam so tests can prove BOTH branches (allow a public-looking
  target, deny a private one) hermetically: CI sandboxes commonly have no egress, and a
  real hostname resolving to a stable non-private IP is not a hermetic fixture. The
  production default is `Samen.Egress.Guard.Resolver.Inet` (real `:inet.getaddr/2`,
  IPv4 **and** IPv6); a test resolver is opt-in only via explicit config, never a silent
  default.

      config :samen_core, Samen.Egress.Guard,
        resolver: Samen.Egress.Guard.Resolver.Test,
        resolver_map: %{"hook.example.test" => {93, 184, 216, 34}}

  A caller may also pass `resolver:`/`env:` directly to `check/2` — that is how
  `Samen.Automation.Actions.Webhook` keeps reading its OWN long-standing
  `config :samen_core, Samen.Automation.Actions.Webhook, resolver: …` key, so the
  extraction changed no configuration surface.

  ## What this guard does NOT do (the honest residual)

  This is layers 1 and 2 of ADR/issue-#25's three: scheme + resolve-then-deny, backed by
  `:autoredirect` being off on every adapter that can be reached from a tenant-supplied
  URL (so a public URL cannot 302-pivot inward after the check). Layer 3 — connecting to
  the *pinned* resolved IP while still presenting the original `Host` header and TLS SNI,
  which closes the DNS-rebinding TOCTOU between `check/2`'s resolve and `:httpc`'s own
  connect-time resolve — is NOT implemented, and is deliberately not faked here. See
  `Samen.Webhook.HttpAdapter.Httpc`'s moduledoc for the mechanism and why it is a
  separate piece of work.
  """

  @compiled_env Mix.env()

  @type reason :: :invalid_url | :invalid_scheme | :https_required | :ssrf_blocked

  @doc """
  Delivery-time guard: scheme check, then resolve-then-deny.

  Options:

    * `:resolver` — a `Samen.Egress.Guard.Resolver` module. Defaults to the
      `config :samen_core, Samen.Egress.Guard, resolver: …` value, else
      `Samen.Egress.Guard.Resolver.Inet`.
    * `:env` — the environment atom the scheme check consults. Defaults to the
      `config :samen_core, Samen.Egress.Guard, env: …` value, else the compiled
      `Mix.env()`.
  """
  @spec check(term(), keyword()) :: :ok | {:error, reason()}
  def check(url, opts \\ []) do
    with {:ok, scheme, host} <- parse(url),
         :ok <- check_scheme(scheme, env(opts)) do
      check_host(host, opts)
    end
  end

  @doc """
  Registration-time guard: scheme check plus a LITERAL private/metadata IP check.

  No DNS. A hostname — even one that resolves privately — passes; `check/2` is the
  authority at delivery time. Accepts the same `:env` option as `check/2`;
  `:resolver` is ignored (nothing is resolved).
  """
  @spec check_literal(term(), keyword()) :: :ok | {:error, reason()}
  def check_literal(url, opts \\ []) do
    with {:ok, scheme, host} <- parse(url),
         :ok <- check_scheme(scheme, env(opts)) do
      case parse_address(host) do
        {:ok, ip} -> if private_ip?(ip), do: {:error, :ssrf_blocked}, else: :ok
        :error -> :ok
      end
    end
  end

  @doc """
  True when `ip` (an `:inet.ip_address/0` tuple) is loopback, private, link-local,
  CGNAT, multicast or otherwise non-public — including the IPv6 equivalents and the
  IPv4-in-IPv6 wrapped forms. See the moduledoc for the full range list.
  """
  @spec private_ip?(term()) :: boolean()
  # --- IPv4 ---
  def private_ip?({0, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({100, b, _, _}) when b in 64..127, do: true
  def private_ip?({127, _, _, _}), do: true
  def private_ip?({169, 254, _, _}), do: true
  def private_ip?({172, b, _, _}) when b in 16..31, do: true
  def private_ip?({192, 0, 0, _}), do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({198, b, _, _}) when b in 18..19, do: true
  def private_ip?({a, _, _, _}) when a >= 224, do: true
  def private_ip?({a, b, c, d})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d),
      do: false

  # --- IPv6: unwrap the IPv4-in-IPv6 forms FIRST, so a wrapped private v4 cannot
  # slide past the v6 clauses below. ::ffff:a.b.c.d (mapped) and ::a.b.c.d
  # (compatible, ::1 excluded by the earlier clause ordering below).
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, w7, w8}), do: private_ip?(unwrap_v4(w7, w8))

  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private_ip?({0, 0, 0, 0, 0, 0, w7, w8}), do: private_ip?(unwrap_v4(w7, w8))
  # NAT64 well-known prefix 64:ff9b::/96 — translates an embedded IPv4.
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, w7, w8}), do: private_ip?(unwrap_v4(w7, w8))
  # fc00::/7 unique-local, fe80::/10 link-local, ff00::/8 multicast.
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFC00 and w1 <= 0xFDFF, do: true
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFF00, do: true

  def private_ip?({_, _, _, _, _, _, _, _}), do: false
  def private_ip?(_other), do: true

  # ---------------------------------------------------------------------------
  # Private

  # An Erlang IPv6 tuple holds 16-bit words; the last two carry the embedded IPv4's
  # four octets. div/rem (not Bitwise) keeps this a plain arithmetic helper.
  defp unwrap_v4(w7, w8) do
    {div(w7, 256), rem(w7, 256), div(w8, 256), rem(w8, 256)}
  end

  defp parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        {:ok, scheme, host}

      _other ->
        {:error, :invalid_url}
    end
  end

  defp parse(_other), do: {:error, :invalid_url}

  defp check_scheme("https", _env), do: :ok
  defp check_scheme("http", env), do: if(env in [:dev, :test], do: :ok, else: {:error, :https_required})
  defp check_scheme(_other, _env), do: {:error, :invalid_scheme}

  # Resolve-then-deny. A literal IP host skips DNS entirely (there is nothing to
  # resolve and a resolver stub must not be able to launder a literal). EVERY address
  # the resolver answers with must be public — one private answer blocks the URL.
  defp check_host(host, opts) do
    case parse_address(host) do
      {:ok, ip} ->
        if private_ip?(ip), do: {:error, :ssrf_blocked}, else: :ok

      :error ->
        case resolver(opts).resolve(host) do
          {:ok, ips} when is_list(ips) and ips != [] ->
            if Enum.any?(ips, &private_ip?/1), do: {:error, :ssrf_blocked}, else: :ok

          {:ok, ip} when is_tuple(ip) ->
            if private_ip?(ip), do: {:error, :ssrf_blocked}, else: :ok

          _other ->
            # Unresolvable, empty, or an unexpected shape: FAIL CLOSED.
            {:error, :ssrf_blocked}
        end
    end
  end

  defp parse_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp resolver(opts) do
    Keyword.get_lazy(opts, :resolver, fn ->
      config() |> Keyword.get(:resolver, Samen.Egress.Guard.Resolver.Inet)
    end)
  end

  defp env(opts) do
    Keyword.get_lazy(opts, :env, fn -> config() |> Keyword.get(:env, @compiled_env) end)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end

defmodule Samen.Egress.Guard.Resolver do
  @moduledoc """
  DNS-resolution seam for `Samen.Egress.Guard` (issue #25 / `T161` §5.3
  "resolve-then-deny loopback/RFC1918/link-local"). Injectable so tests can prove BOTH
  branches without real DNS. `resolve/1` may answer with a single address or a list;
  the guard denies the URL if ANY answer is private, and denies on any error.
  """
  @callback resolve(host :: String.t()) ::
              {:ok, :inet.ip_address() | [:inet.ip_address()]} | {:error, term()}
end

defmodule Samen.Egress.Guard.Resolver.Inet do
  @moduledoc """
  Production resolver — real `:inet.getaddrs/2` over BOTH families. Every A and AAAA
  answer is returned so the guard tests all of them: a name that answers with one
  public A record and one private AAAA record must be refused, not allowed on the
  strength of the first answer. When neither family resolves, the error propagates and
  the guard fails closed.
  """
  @behaviour Samen.Egress.Guard.Resolver

  @impl true
  def resolve(host) do
    charlist = String.to_charlist(host)

    addrs =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, ips} -> ips
          {:error, _} -> []
        end
      end)

    case addrs do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end
end

defmodule Samen.Egress.Guard.Resolver.Test do
  @moduledoc """
  Test resolver — a fixed hostname -> address(es) map configured via

      config :samen_core, Samen.Egress.Guard,
        resolver: Samen.Egress.Guard.Resolver.Test,
        resolver_map: %{"hook.example.test" => {93, 184, 216, 34}}

  A value may be a single address tuple or a list of them (to exercise the
  "one public answer, one private answer" case). An unmapped host resolves
  `{:error, :nxdomain}` — fail-closed like a real resolver on a bogus name, never a
  silent allow.
  """
  @behaviour Samen.Egress.Guard.Resolver

  @impl true
  def resolve(host) do
    map =
      Application.get_env(:samen_core, Samen.Egress.Guard, [])
      |> Keyword.get(:resolver_map, %{})

    case Map.get(map, host) do
      nil -> {:error, :nxdomain}
      ip -> {:ok, ip}
    end
  end
end
