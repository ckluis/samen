defmodule DriftwoodWeb.IdentitySpineRenderTest do
  @moduledoc """
  T148 — a live HTTP dead-render smoke over DriftwoodWeb.Endpoint proving the mounted framework
  identity-spine surfaces actually RENDER in driftwood (not merely that a route row exists): the
  pre-actor `GET /signup` (the start of the signup → verify → onboarding journey) and the
  teammate `GET /invite/:token` (item 5 — the invite-accept surface is reachable now that the
  spine is mounted). Both are pre-actor/public, so no seeded actor is needed.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint DriftwoodWeb.Endpoint

  setup do
    start_supervised!(DriftwoodWeb.Endpoint)
    :ok
  end

  test "GET /signup renders the framework registration surface" do
    conn = get(build_conn(), "/signup")
    assert html_response(conn, 200)
  end

  test "GET /invite/:token renders the framework invite-accept surface" do
    conn = get(build_conn(), "/invite/some-token")
    assert html_response(conn, 200)
  end
end
