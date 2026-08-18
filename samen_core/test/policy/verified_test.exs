defmodule Samen.Policy.VerifiedTest do
  @moduledoc """
  ADR-035 §5 A2 — `Samen.Policy.Verified`'s pure `match?/3` mechanism: an
  unverified actor (no `verified?` key, `verified?: false`, or a non-map
  actor) is denied; a verified actor (`verified?: true`) is allowed. The
  integration proof (this check wired onto `Identity.Invitation.create`,
  denying an unverified credential the invite capability a verified one
  holds) lives in `samen_web/test/samen/web/auth/confirm_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Samen.Policy.Verified

  test "RED PATH: an actor with no verified? key is denied" do
    refute Verified.match?(%{id: "u1", org_id: "o1"}, %{}, [])
  end

  test "RED PATH: verified?: false is denied" do
    refute Verified.match?(%{id: "u1", org_id: "o1", verified?: false}, %{}, [])
  end

  test "RED PATH: a non-map actor (nil / unauthenticated) is denied" do
    refute Verified.match?(nil, %{}, [])
  end

  test "POSITIVE CONTROL: verified?: true is allowed (the deny above is not vacuous)" do
    assert Verified.match?(%{id: "u1", org_id: "o1", verified?: true}, %{}, [])
  end

  test "describe/1 documents the mechanism" do
    assert Verified.describe([]) =~ "verified?"
  end
end
