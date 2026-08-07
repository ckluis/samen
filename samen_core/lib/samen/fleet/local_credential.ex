defmodule Samen.Fleet.LocalCredential do
  @moduledoc """
  The **app-side** (reporting-side) credential store — what THIS product holds for
  itself: mode A's shared secret (read from `SAMEN_FLEET_PROBE_SECRET`, no local
  persistence needed — it is operator-pasted config, re-read at boot), or mode B's
  own Ed25519 keypair plus the cockpit's public key (generated ONCE at first
  enrollment and needing durable persistence across restarts).

  This is a **behaviour + a reference Agent-backed implementation**
  (`Samen.Fleet.LocalCredential.Agent`), not a fixed schema — a production host's
  mode-B private key custody is host-local state (ADR §4.2/§4.3: "the app stores it
  KMS-wrapped too"), and the ADR deliberately does not mandate one storage shape for
  it (unlike the flt_* COCKPIT-side registry, which IS a fixed schema because many
  cockpits must interoperate with many apps over the same wire). A production host
  wires its own implementation (a one-row local table, a secret manager, …) via:

      config :my_app, :fleet_local_credential, MyApp.Fleet.LocalCredential

  The reference `Agent` implementation is what T82's own tests/probes use, and is
  good enough for `:embedded` mode's zero-config default (which never calls this
  module at all — §8.1: "no credential, no secret, no HTTP call").
  """

  @type mode_a :: %{kind: :shared_secret, secret: binary()}
  @type mode_b :: %{
          kind: :ed25519,
          app_id: String.t(),
          private_key: binary(),
          cockpit_public_key: binary(),
          key_version: pos_integer()
        }

  @callback put(host :: atom(), mode_a() | mode_b()) :: :ok
  @callback fetch(host :: atom()) :: {:ok, mode_a() | mode_b()} | {:error, :not_configured}

  @doc "The configured implementation for `host` (defaults to the reference Agent)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:samen_core, :fleet_local_credential, __MODULE__.Agent)

  @doc "Store this host's local fleet credential material."
  @spec put(atom(), mode_a() | mode_b()) :: :ok
  def put(host, credential), do: impl().put(host, credential)

  @doc """
  Fetch this host's local fleet credential material. `{:error, :not_configured}` —
  never a fabricated credential — when nothing has been stored (mode A: the
  `SAMEN_FLEET_PROBE_SECRET` env var was never set; mode B: enrollment never
  completed). This is the RP-J-10 fail-honest floor for the app side.
  """
  @spec fetch(atom()) :: {:ok, mode_a() | mode_b()} | {:error, :not_configured}
  def fetch(host), do: impl().fetch(host)

  defmodule Agent do
    @moduledoc "Reference in-process implementation (T82 tests/probes; not durable across a BEAM restart)."
    @behaviour Samen.Fleet.LocalCredential

    @name __MODULE__

    defp ensure_started do
      case Process.whereis(@name) do
        nil ->
          case Elixir.Agent.start_link(fn -> %{} end, name: @name) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end

        _pid ->
          :ok
      end
    end

    @impl true
    def put(host, credential) do
      ensure_started()
      Elixir.Agent.update(@name, &Map.put(&1, host, credential))
    end

    @impl true
    def fetch(host) do
      ensure_started()

      case Elixir.Agent.get(@name, &Map.get(&1, host)) do
        nil -> {:error, :not_configured}
        credential -> {:ok, credential}
      end
    end

    @doc "Test support: clear all stored local credentials."
    def reset do
      ensure_started()
      Elixir.Agent.update(@name, fn _ -> %{} end)
    end
  end
end
