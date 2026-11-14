defmodule Samen.AuditChain.WriterTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.AuditChain.Writer.write/2`, the one path that seals an `aud_event` into the
  tamper-evident chain. Pinned here: the argument guard (a non-repo or non-map never reaches the DB) and that the
  event row keeps the caller's `event_type` (defaulting to "system" only when none was given) — the chain entry and
  the event row must agree on what happened.
  """
  use ExUnit.Case, async: false

  alias Samen.AuditChain.Writer

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    :ok
  end

  defp attrs(extra) do
    Map.merge(
      %{
        org_id: Ecto.UUID.generate(),
        subject_id: "subject-#{System.unique_integer([:positive])}",
        actor_id: "actor-1",
        detail: "probe"
      },
      extra
    )
  end

  test "the event row and the chain entry both carry the caller's event_type" do
    assert {:ok, %{aud_event: aud, chain: chain}} = Writer.write(@repo, attrs(%{event_type: "custom_probe"}))
    assert aud.event_type == "custom_probe"
    assert chain.event_type == "custom_probe"
  end

  test "with no event_type both default to \"system\"" do
    assert {:ok, %{aud_event: aud, chain: chain}} = Writer.write(@repo, attrs(%{}))
    assert aud.event_type == "system"
    assert chain.event_type == "system"
  end

  test "a non-repo first argument or a non-map second argument is refused by function clause, before any write" do
    for args <- [["not-a-repo", attrs(%{})], [@repo, "attrs"], [@repo, [org_id: "x"]], [nil, nil]] do
      assert_raise FunctionClauseError, fn -> apply(Writer, :write, args) end
    end
  end
end
