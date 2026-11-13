defmodule Samen.SeedBootTest do
  @moduledoc """
  A seed task must not start the HTTP listener: dev config sets `server: true`, and a listener started by
  `mix <app>.seed` dies with `:eaddrinuse` while the dev server runs. `Samen.SeedBoot` forces `server: false`
  for the seed VM only.
  """
  use ExUnit.Case, async: false

  @app :samen_core_seed_boot_probe
  @endpoint Samen.SeedBootTest.FakeEndpoint

  setup do
    on_exit(fn -> Application.delete_env(@app, @endpoint) end)
  end

  test "disable_listener!/2 turns server off and preserves every other endpoint option" do
    Application.put_env(@app, @endpoint, server: true, http: [port: 4000], secret_key_base: "k")

    assert :ok = Samen.SeedBoot.disable_listener!(@app, @endpoint)

    cfg = Application.get_env(@app, @endpoint)
    assert cfg[:server] == false
    assert cfg[:http] == [port: 4000]
    assert cfg[:secret_key_base] == "k"
  end

  test "disable_listener!/2 also works when the endpoint has no config yet" do
    assert :ok = Samen.SeedBoot.disable_listener!(@app, @endpoint)
    assert Application.get_env(@app, @endpoint) == [server: false]
  end
end
