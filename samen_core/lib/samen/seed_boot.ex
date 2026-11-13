defmodule Samen.SeedBoot do
  @moduledoc """
  Boots a host for a seed task WITHOUT the HTTP listener.

  A host's dev config sets `server: true` on its endpoint (so `mix phx.server` / `iex -S mix` serve). A seed task
  that used `@requirements ["app.start"]` therefore started the listener too, and died with `:eaddrinuse` whenever
  the dev server was already running. A seed task needs the repo, the vault and the supervision tree — not a port —
  so it calls `start!/2` instead: config is loaded, the endpoint's `server` flag is forced off for THIS VM only,
  and then the application is started.

  The three seed tasks (`mix driftwood.seed`, `mix pawchart.seed`, and the generated app's `mix <app>.seed`) all
  use it, so every host gets the behaviour from one place.
  """

  @doc """
  Loads config, disables the endpoint's HTTP listener (`server: false`, every other endpoint option preserved), then
  runs `app.start`. Idempotent.
  """
  @spec start!(atom(), module()) :: :ok
  def start!(otp_app, endpoint) when is_atom(otp_app) and is_atom(endpoint) do
    Mix.Task.run("app.config")
    disable_listener!(otp_app, endpoint)
    Mix.Task.run("app.start")
    :ok
  end

  @doc "Forces `server: false` on `endpoint`'s application env, preserving its other options."
  @spec disable_listener!(atom(), module()) :: :ok
  def disable_listener!(otp_app, endpoint) when is_atom(otp_app) and is_atom(endpoint) do
    current = Application.get_env(otp_app, endpoint, [])
    Application.put_env(otp_app, endpoint, Keyword.put(current, :server, false))
    :ok
  end
end
