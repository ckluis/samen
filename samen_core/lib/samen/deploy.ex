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

  A URL carrying `ssl=false` would override the TLS options (`Ecto.Repo.Supervisor` merges the URL over the repo
  config), so it RAISES too.
  """
  require Logger

  @type getenv :: (String.t() -> String.t() | nil)

  @doc """
  The `:ssl` option for a prod Repo. `urls` are the database URLs the process will connect with (`nil`/`""` entries
  are ignored); `getenv` is injectable for tests.
  """
  @spec db_ssl_opts([String.t() | nil], getenv()) :: keyword()
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
        Logger.warning(
          "DATABASE_SSL_VERIFY=none: the database server certificate is NOT verified; a man in the middle can " <>
            "read and alter the session. Use only on a private network, and prefer DATABASE_SSL_CACERTFILE."
        )

        [verify: :verify_none]

      cafile != nil ->
        unless File.regular?(cafile) do
          raise ArgumentError,
                "DATABASE_SSL_CACERTFILE=#{inspect(cafile)} is not a readable file (fail-closed)."
        end

        [verify: :verify_peer, cacertfile: cafile, customize_hostname_check: hostname_check()]

      true ->
        [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: hostname_check()]
    end
  end

  defp hostname_check, do: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]

  defp env(getenv, var) do
    case getenv.(var) do
      "" -> nil
      value -> value
    end
  end

  defp assert_tls_not_disabled!(url) when url in [nil, ""], do: :ok

  defp assert_tls_not_disabled!(url) when is_binary(url) do
    query = URI.parse(url).query || ""

    if Map.get(URI.decode_query(query), "ssl") == "false" do
      raise ArgumentError,
            "a database URL carries ssl=false, which would switch TLS off for the prod connection (fail-closed). " <>
              "Remove it."
    end

    :ok
  end
end
