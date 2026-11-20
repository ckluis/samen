defmodule Samen.DeployDbSslTest do
  @moduledoc """
  ARCH-12 — the generated prod database connection VERIFIES the server certificate.

  Proven on `Samen.Deploy.db_ssl_opts/2` directly (default, custom CA, loud opt-out, fail-closed values) and by
  EVALUATING the generated `config/runtime.exs` with `Config.Reader`, so a template that went back to
  `verify: :verify_none` (or stopped calling the helper) fails here. The real TLS handshake is Postgrex's/OTP's.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Samen.Deploy
  alias Samen.Gen.App, as: Gen

  defp env(map), do: fn k -> Map.get(map, k) end

  @url "postgres://u:p@ep-1-pooler.eu-central-1.aws.neon.tech/acme?sslmode=require"

  describe "db_ssl_opts/2" do
    test "default: verify_peer, the OS CA store, the :https hostname match, and no pinned SNI" do
      opts = Deploy.db_ssl_opts([@url], env(%{}))

      assert opts[:verify] == :verify_peer
      assert [_ | _] = opts[:cacerts]
      assert [match_fun: fun] = opts[:customize_hostname_check]
      assert is_function(fun, 2)
      # Postgrex sets SNI per connection from the host it dials (the pooled and the direct host differ)
      refute Keyword.has_key?(opts, :server_name_indication)
      refute Keyword.has_key?(opts, :cacertfile)
    end

    test "default also holds for an IP-literal host, a hostless URL, nil entries and an explicit `peer`" do
      for urls <- [["postgres://u:p@10.0.0.5/acme"], ["postgres://u:p@[::1]/acme"], ["postgres:///acme"], [nil, ""]] do
        opts = Deploy.db_ssl_opts(urls, env(%{"DATABASE_SSL_VERIFY" => "peer"}))
        assert opts[:verify] == :verify_peer
        refute Keyword.has_key?(opts, :server_name_indication)
      end
    end

    test "an empty env value counts as unset" do
      opts = Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_VERIFY" => "", "DATABASE_SSL_CACERTFILE" => ""}))
      assert opts[:verify] == :verify_peer
      assert Keyword.has_key?(opts, :cacerts)
    end

    test "a custom CA file replaces the OS store and keeps peer + hostname verification" do
      file = Path.join(System.tmp_dir!(), "samen_db_ca_#{System.unique_integer([:positive])}.pem")
      File.write!(file, "not a real ca; existence is what is checked here")
      on_exit(fn -> File.rm(file) end)

      opts = Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_CACERTFILE" => file}))

      assert opts[:verify] == :verify_peer
      assert opts[:cacertfile] == file
      refute Keyword.has_key?(opts, :cacerts)
      assert opts[:customize_hostname_check][:match_fun]
    end

    test "RED: a CA file that does not exist raises" do
      assert_raise ArgumentError, ~r/DATABASE_SSL_CACERTFILE.*not a readable file/, fn ->
        Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_CACERTFILE" => "/nonexistent/samen-ca.pem"}))
      end
    end

    test "explicit none is the opt-out, and it WARNS" do
      log =
        capture_io(:stderr, fn ->
          assert Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_VERIFY" => "none"})) == [verify: :verify_none]
        end)

      assert log =~ "DATABASE_SSL_VERIFY=none"
      assert log =~ "NOT verified"
    end

    test "POSITIVE CONTROL: the verifying default logs no warning" do
      assert capture_io(:stderr, fn -> Deploy.db_ssl_opts([@url], env(%{})) end) == ""
    end

    test "RED: an unrecognised DATABASE_SSL_VERIFY raises (fail-closed), naming the value" do
      for bad <- ["false", "off", "0", "NONE", "verify_none", "full"] do
        assert_raise ArgumentError, ~r/DATABASE_SSL_VERIFY=.*#{bad}.*not recognised/, fn ->
          Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_VERIFY" => bad}))
        end
      end
    end

    test "RED: none together with a CA file is contradictory and raises" do
      assert_raise ArgumentError, ~r/contradict/, fn ->
        Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_VERIFY" => "none", "DATABASE_SSL_CACERTFILE" => "/x"}))
      end
    end

    test "RED: a URL carrying ssl=false (either connection) raises; ssl=true and sslmode do not" do
      assert_raise ArgumentError, ~r/ssl=false/, fn -> Deploy.db_ssl_opts(["postgres://h/db?ssl=false"], env(%{})) end

      assert_raise ArgumentError, ~r/ssl=false/, fn ->
        Deploy.db_ssl_opts([@url, "postgres://h/db?sslmode=require&ssl=false"], env(%{}))
      end

      assert Deploy.db_ssl_opts(["postgres://h/db?ssl=true", @url, nil], env(%{}))[:verify] == :verify_peer
    end
  end

  describe "db_ssl_opts/2: URL values that would disable or break TLS" do
    @secret_url "postgres://u:hunter2secret@db.example/acme"

    test "RED: any ssl= value other than true raises, naming the variable and never the URL" do
      for bad <- ["false", "FALSE", "False", "0", "off", "no", "1", "yes", ""] do
        url = @secret_url <> "?ssl=" <> bad

        err =
          assert_raise ArgumentError, ~r/DATABASE_DIRECT_URL carries ssl=#{bad}:/, fn ->
            Deploy.db_ssl_opts([{"DATABASE_URL", @url}, {"DATABASE_DIRECT_URL", url}], env(%{}))
          end

        refute err.message =~ "hunter2secret"
        refute err.message =~ "db.example"
      end
    end

    test "RED: ssl=true followed by a later ssl=<bad> still raises (every pair is checked)" do
      assert_raise ArgumentError, ~r/DATABASE_URL carries ssl=0/, fn ->
        Deploy.db_ssl_opts([{"DATABASE_URL", @secret_url <> "?ssl=true&ssl=0"}], env(%{}))
      end
    end

    test "RED: sslmode=disable|allow|prefer raises, naming the variable; require/verify-* do not" do
      for bad <- ["disable", "allow", "prefer"] do
        err =
          assert_raise ArgumentError, ~r/DATABASE_URL carries sslmode=#{bad}/, fn ->
            Deploy.db_ssl_opts([{"DATABASE_URL", @secret_url <> "?sslmode=" <> bad}], env(%{}))
          end

        refute err.message =~ "hunter2secret"
      end

      for ok <- ["require", "verify-ca", "verify-full"] do
        assert Deploy.db_ssl_opts([{"DATABASE_URL", @secret_url <> "?sslmode=" <> ok}], env(%{}))[:verify] == :verify_peer
      end
    end

    test "POSITIVE CONTROL: ssl=true, a nil tuple value and an unlabelled entry are accepted" do
      assert Deploy.db_ssl_opts([{"DATABASE_URL", @secret_url <> "?ssl=true"}, {"DATABASE_DIRECT_URL", nil}], env(%{}))[:verify] ==
               :verify_peer
    end

    test "RED: an unreadable CA file raises (a real read, not a regular-file check)" do
      file = Path.join(System.tmp_dir!(), "samen_db_ca_unreadable_#{System.unique_integer([:positive])}.pem")
      File.write!(file, "x")
      File.chmod!(file, 0o000)
      on_exit(fn -> File.rm(file) end)

      if match?({:error, _}, File.open(file, [:read])) do
        assert_raise ArgumentError, ~r/DATABASE_SSL_CACERTFILE.*not a readable file/, fn ->
          Deploy.db_ssl_opts([@url], env(%{"DATABASE_SSL_CACERTFILE" => file}))
        end
      end
    end
  end

  describe "what the Repo and the lease really receive (pins Ecto's merge, which the design leans on)" do
    defmodule TlsRepo do
      use Ecto.Repo, otp_app: :samen_core_deploy_ssl_probe, adapter: Ecto.Adapters.Postgres
    end

    @probe_app :samen_core_deploy_ssl_probe

    defp repo_config(url) do
      ssl = Deploy.db_ssl_opts([{"DATABASE_URL", url}], env(%{"DATABASE_SSL_VERIFY" => "peer"}))
      Application.put_env(@probe_app, TlsRepo, url: url, ssl: ssl, pool_size: 1)
      on_exit(fn -> Application.delete_env(@probe_app, TlsRepo) end)

      ExUnit.CaptureLog.with_log(fn ->
        {:ok, config} = Ecto.Repo.Supervisor.init_config(:runtime, TlsRepo, @probe_app, [])
        config
      end)
      |> then(fn {config, _log} -> {config, ssl} end)
    end

    test "?sslmode=require and ?ssl=true both leave the hardened list on the Repo" do
      for q <- ["sslmode=require", "ssl=true", "sslmode=require&channel_binding=require"] do
        {config, ssl} = repo_config("postgres://u:p@db.example/acme?" <> q)
        assert config[:ssl] == ssl
        assert config[:ssl][:verify] == :verify_peer
      end
    end

    test "the lease inherits that list from the Repo config, with the direct URL's own host" do
      {config, ssl} = repo_config("postgres://u:p@pooled.example/acme?sslmode=require")

      defmodule Stub do
        def config, do: Process.get(:stub_repo_config)
      end

      Process.put(:stub_repo_config, config)

      opts =
        Samen.SingleNode.Lease.connect_opts([repo: Stub, lease_url: "postgres://u:p@direct.example/acme?ssl=true"], %{lease_url: nil})

      assert opts[:ssl] == ssl
      assert opts[:hostname] == "direct.example"
    end
  end

  describe "the generated --deploy config/runtime.exs" do
    @secrets %{
      "DATABASE_URL" => @url,
      "SECRET_KEY_BASE" => String.duplicate("k", 64),
      "PHX_HOST" => "acme.example",
      "SAMEN_KMS_KEY_ID" => "kms-key",
      "SAMEN_KMS_REGION" => "eu-west-1"
    }
    @tls_vars ["DATABASE_DIRECT_URL", "DATABASE_SSL_VERIFY", "DATABASE_SSL_CACERTFILE"]

    setup do
      b =
        Gen.bindings(
          Gen.build_spec(module: "Acme", prefix: "ac", abbrev: "acm", target: Gen.default_target(), deploy: true)
        )

      runtime =
        Enum.find_value(Samen.Gen.Templates.files(true, true, true), fn {path, template} ->
          if Gen.render(path, b) == "config/runtime.exs", do: Gen.render(template, b)
        end)

      dir = Path.join(System.tmp_dir!(), "samen_db_ssl_runtime_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "runtime.exs")
      File.write!(path, runtime)

      keys = Map.keys(@secrets) ++ @tls_vars
      prev = Map.new(keys, &{&1, System.get_env(&1)})
      Enum.each(@tls_vars, &System.delete_env/1)
      System.put_env(@secrets)

      on_exit(fn ->
        File.rm_rf!(dir)

        Enum.each(prev, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      %{path: path, source: runtime}
    end

    defp repo_ssl(path), do: Config.Reader.read!(path, env: :prod)[:acme][Acme.Repo][:ssl]

    test "verifies the server certificate by default", %{path: path, source: source} do
      refute source =~ "verify_none"
      ssl = repo_ssl(path)
      assert ssl[:verify] == :verify_peer
      assert [_ | _] = ssl[:cacerts]
    end

    test "the opt-out reaches the Repo, loudly", %{path: path} do
      System.put_env("DATABASE_SSL_VERIFY", "none")
      log = capture_io(:stderr, fn -> assert repo_ssl(path) == [verify: :verify_none] end)
      assert log =~ "NOT verified"
    end

    test "RED: an unrecognised value, or ssl=false on DATABASE_DIRECT_URL, refuses to boot", %{path: path} do
      System.put_env("DATABASE_SSL_VERIFY", "maybe")
      assert_raise ArgumentError, ~r/not recognised/, fn -> Config.Reader.read!(path, env: :prod) end

      System.delete_env("DATABASE_SSL_VERIFY")
      System.put_env("DATABASE_DIRECT_URL", "postgres://u:p@db.example/acme?ssl=false")
      assert_raise ArgumentError, ~r/DATABASE_DIRECT_URL carries ssl=false/, fn -> Config.Reader.read!(path, env: :prod) end

      System.put_env("DATABASE_DIRECT_URL", "postgres://u:p@db.example/acme?ssl=FALSE")
      assert_raise ArgumentError, ~r/DATABASE_DIRECT_URL carries ssl=FALSE/, fn -> Config.Reader.read!(path, env: :prod) end
    end

    test "DATABASE_DIRECT_URL is honoured as the lease url and the Repo ssl still verifies", %{path: path} do
      System.put_env("DATABASE_DIRECT_URL", "postgres://u:p@db.example/acme?sslmode=require")
      config = Config.Reader.read!(path, env: :prod)
      assert config[:samen_core][Samen.SingleNode][:lease_url] =~ "db.example"
      assert config[:acme][Acme.Repo][:ssl][:verify] == :verify_peer
    end
  end
end
