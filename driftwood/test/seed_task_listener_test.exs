defmodule Driftwood.SeedTaskListenerTest do
  @moduledoc """
  `mix driftwood.seed` must not start the HTTP listener (dev config has `server: true`; a second listener dies with
  `:eaddrinuse` while `mix phx.server` is up). The seed task boots through `Samen.SeedBoot`, whose effect on the
  endpoint config Phoenix itself reads is proven here.
  """
  use ExUnit.Case, async: false

  test "after the seed task's boot step Phoenix will not serve the endpoint, whatever the dev config said" do
    original = Application.get_env(:driftwood, DriftwoodWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:driftwood, DriftwoodWeb.Endpoint, original) end)

    Application.put_env(:driftwood, DriftwoodWeb.Endpoint, Keyword.put(original, :server, true))
    assert Phoenix.Endpoint.server?(:driftwood, DriftwoodWeb.Endpoint)

    Samen.SeedBoot.disable_listener!(:driftwood, DriftwoodWeb.Endpoint)
    refute Phoenix.Endpoint.server?(:driftwood, DriftwoodWeb.Endpoint)
  end
end
