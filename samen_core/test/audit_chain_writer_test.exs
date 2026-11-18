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

  describe "the event and its chain entry are one unit (both rows or neither)" do
    # The chain append fails AFTER the `aud_event` insert: a subject payload with no subject to key it under is a
    # validation error that is returned, never raised, so a caller's transaction survives it.
    defp failing_second_statement(subject), do: attrs(%{subject_id: subject, subject_payload: "x"}) |> Map.put(:subject_id, nil) |> Map.put(:detail, "orphan-probe-" <> subject)

    defp events_with_detail(detail),
      do: @repo.query!("SELECT count(*) FROM aud_event WHERE aud_detail = $1", [detail]).rows |> hd() |> hd()

    test "outside a transaction a failed chain append leaves no orphan aud_event" do
      refute @repo.in_transaction?()
      a = failing_second_statement("out-#{System.unique_integer([:positive])}")
      assert {:error, :subject_payload_requires_subject_id} = Writer.write(@repo, a)
      assert events_with_detail(a.detail) == 0
    end

    test "inside a caller's transaction that tolerates the error, a failed chain append leaves no orphan aud_event" do
      a = failing_second_statement("in-#{System.unique_integer([:positive])}")

      assert {:ok, :tolerated} =
               @repo.transaction(fn ->
                 assert @repo.in_transaction?()
                 assert {:error, :subject_payload_requires_subject_id} = Writer.write(@repo, a)
                 assert events_with_detail(a.detail) == 0
                 :tolerated
               end)

      assert events_with_detail(a.detail) == 0
    end

    test "control: the healthy path writes both rows, inside and outside a transaction, and a later write still chains" do
      org = Ecto.UUID.generate()
      count = fn -> @repo.query!("SELECT count(*) FROM aud_chain WHERE ach_org_id = $1", [org]).rows |> hd() |> hd() end

      assert {:ok, %{aud_event: %{id: id1}, chain: %{seq: 0, aud_id: id1}}} =
               Writer.write(@repo, attrs(%{org_id: org, detail: "healthy-out"}))

      assert {:ok, {:ok, %{aud_event: %{id: id2}, chain: %{seq: 1, aud_id: id2}}}} =
               @repo.transaction(fn ->
                 a = failing_second_statement("mid-#{System.unique_integer([:positive])}") |> Map.put(:org_id, org)
                 assert {:error, _} = Writer.write(@repo, a)
                 Writer.write(@repo, attrs(%{org_id: org, detail: "healthy-in"}))
               end)

      assert count.() == 2
      assert events_with_detail("healthy-out") == 1 and events_with_detail("healthy-in") == 1
    end
  end
end
