defmodule Samen.Deploy do
  @moduledoc """
  Boot-time helpers the generated `--deploy` `config/runtime.exs` calls (and any host that wants the same posture),
  kept in the kernel so they are unit-testable instead of living as untested template text.

  ## `db_ssl_opts/2` — the database connection verifies the server certificate

  A prod Postgres connection that does not verify the server certificate hands the whole session (ciphertexts,
  blind indexes, session digests) to anyone on the path. The default here is `verify: :verify_peer` against the
  operating-system CA store (`:public_key.cacerts_get/0`) with the `:https` hostname match (`*.neon.tech`-style
  wildcards match). No `:server_name_indication` is set on purpose: Postgrex sets it per connection from the host
  it actually dials (`Postgrex.Protocol.do_handshake/3`: `Keyword.put_new(ssl_opts, :server_name_indication, host)`
  when the host is a charlist), so the same option list is right for `DATABASE_URL` and for the single-node lease's
  `DATABASE_DIRECT_URL`, which dials a different (unpooled) host; a value derived from one URL would fail the other.

  Environment (read once at boot; an empty value counts as unset):

    * `DATABASE_SSL_CACERTFILE=/path/ca.pem` verify against this CA bundle instead of the OS store (a private CA).
      The file must exist (fail-closed).
    * `DATABASE_SSL_VERIFY=peer` (the default, may be spelled out) or `none`. `none` is the loud opt-out for a
      private network with a self-signed certificate: it logs a warning at every boot. Any other value RAISES.
      `none` together with a CA file is contradictory and RAISES.

  `urls` entries may be `{"ENV_VAR_NAME", url}` so a refusal names the variable (never the URL: it holds the password).
  A URL `ssl=` value other than `true` RAISES: `Ecto.Repo.Supervisor.parse_uri_query` turns `ssl=false` into `false`
  (which would override the TLS options, since it merges the URL over the repo config) and any other spelling
  (`FALSE`, `0`, `off`, empty) into a string, which Postgrex cannot interpret (`CaseClauseError` on every connect).
  `sslmode=disable|allow|prefer` RAISES as well: Postgrex ignores `sslmode`, so those would only mislead the operator
  (`require`, `verify-ca`, `verify-full` are ignored too; verification is set by the environment above).

  The `DATABASE_SSL_VERIFY=none` warning goes to stderr directly, not through `Logger`: `config/runtime.exs` is
  evaluated by the release's config provider before the Logger application starts, and `IO.puts(:stderr, _)` is what
  reliably shows there.
  """

  @type getenv :: (String.t() -> String.t() | nil)
  @type url_entry :: String.t() | nil | {String.t(), String.t() | nil}

  @doc """
  The `:ssl` option for a prod Repo. `urls` are the database URLs the process will connect with (`nil`/`""` entries
  are ignored); `getenv` is injectable for tests.
  """
  @spec db_ssl_opts([url_entry()], getenv()) :: keyword()
  def db_ssl_opts(urls, getenv \\ &System.get_env/1) when is_list(urls) do
    Enum.each(urls, &assert_tls_not_disabled!/1)

    verify = env(getenv, "DATABASE_SSL_VERIFY")
    cafile = env(getenv, "DATABASE_SSL_CACERTFILE")

    cond do
      verify not in [nil, "peer", "none"] ->
        raise ArgumentError,
              "DATABASE_SSL_VERIFY=#{inspect(verify)} is not recognised (fail-closed): use `peer` (the default) " <>
                "or `none`, or unset it."

      verify == "none" and cafile != nil ->
        raise ArgumentError,
              "DATABASE_SSL_VERIFY=none and DATABASE_SSL_CACERTFILE are both set: they contradict each other " <>
                "(fail-closed). Unset one."

      verify == "none" ->
        IO.puts(
          :stderr,
          "[warning] DATABASE_SSL_VERIFY=none: the database server certificate is NOT verified; a man in the " <>
            "middle can read and alter the session. Use only on a private network, and prefer DATABASE_SSL_CACERTFILE."
        )

        [verify: :verify_none]

      cafile != nil ->
        # a real read, not File.regular?/1: a root-owned 0600 file is "regular" but the app (a different user) fails
        # later inside the TLS handshake with an obscure :ssl options error.
        case File.open(cafile, [:read]) do
          {:ok, io} ->
            File.close(io)

          {:error, reason} ->
            raise ArgumentError,
                  "DATABASE_SSL_CACERTFILE=#{inspect(cafile)} is not a readable file (#{:file.format_error(reason)}) (fail-closed)."
        end

        [verify: :verify_peer, cacertfile: cafile, customize_hostname_check: hostname_check()]

      true ->
        [verify: :verify_peer, cacerts: os_cacerts!(), customize_hostname_check: hostname_check()]
    end
  end

  defp os_cacerts! do
    case :public_key.cacerts_get() do
      [_ | _] = certs -> certs
      _ -> no_os_cacerts!()
    end
  rescue
    _ -> no_os_cacerts!()
  end

  defp no_os_cacerts! do
    raise ArgumentError,
          "the operating-system CA bundle could not be loaded (fail-closed): install it (the `ca-certificates` " <>
            "package) in the image, or set DATABASE_SSL_CACERTFILE=/path/to/ca.pem."
  end

  defp hostname_check, do: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]

  defp env(getenv, var) do
    case getenv.(var) do
      "" -> nil
      value -> value
    end
  end

  defp assert_tls_not_disabled!({name, url}) when is_binary(name), do: assert_url!(name, url)
  defp assert_tls_not_disabled!(url), do: assert_url!("a database URL (DATABASE_URL or DATABASE_DIRECT_URL)", url)

  defp assert_url!(_name, url) when url in [nil, ""], do: :ok

  defp assert_url!(name, url) when is_binary(url) do
    # NEVER interpolate the URL: it carries the password.
    (URI.parse(url).query || "")
    |> URI.query_decoder()
    |> Enum.each(fn
      {"ssl", "true"} ->
        :ok

      {"ssl", value} ->
        raise ArgumentError,
              "#{name} carries ssl=#{value}: only ssl=true is valid, and ssl=false (or any other spelling) " <>
                "would switch TLS off or crash every connection (fail-closed). Remove it from the variable " <>
                "(TLS is always on; verification is set by DATABASE_SSL_VERIFY / DATABASE_SSL_CACERTFILE)."

      {"sslmode", value} when value in ["disable", "allow", "prefer"] ->
        raise ArgumentError,
              "#{name} carries sslmode=#{value}, which asks for TLS to be optional or off (fail-closed; Postgrex " <>
                "ignores sslmode and always uses TLS here). Remove it, or use sslmode=require."

      _ ->
        :ok
    end)
  end
end
