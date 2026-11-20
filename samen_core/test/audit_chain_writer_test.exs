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

  describe "the savepoint holds on EVERY exit, and its own statements honour the error contract" do
    # A KMS adapter that RAISES or EXITS in `unwrap/1`, which `AuditChain.append` calls AFTER the `aud_event` insert when
    # a `subject_payload` is given: a non-DB failure, so Postgres does not abort the transaction.
    defmodule Hostile do
      @moduledoc false
      def unwrap(_subject), do: apply(:erlang, :get, [{__MODULE__, :mode}]) |> go()
      defp go(:raise), do: raise("kms adapter blew up")
      defp go(:exit), do: exit(:kms_gone)
      defp go(:throw), do: throw(:kms_thrown)
    end

    defp with_hostile_kms(mode, fun) do
      previous = Application.get_env(:samen_core, :kms_adapter)
      Process.put({Hostile, :mode}, mode)
      Application.put_env(:samen_core, :kms_adapter, Hostile)

      try do
        fun.()
      after
        if previous, do: Application.put_env(:samen_core, :kms_adapter, previous), else: Application.delete_env(:samen_core, :kms_adapter)
      end
    end

    defp payload_attrs(tag), do: attrs(%{subject_payload: "payload", detail: "hostile-#{tag}-#{System.unique_integer([:positive])}"})

    test "RED: a non-DB raise, exit or throw after the event insert leaves no orphan aud_event in a caller that rescues and goes on" do
      for {mode, catcher} <- [raise: :error, exit: :exit, throw: :throw] do
        a = payload_attrs(mode)

        assert {:ok, :carried_on} =
                 @repo.transaction(fn ->
                   # control: the injected failure really is raised, by the adapter, from inside the chain append
                   assert_hostile(mode, catcher, fn -> with_hostile_kms(mode, fn -> Samen.AuditChain.append(Map.put(a, :aud_id, Ecto.UUID.generate()), repo: @repo) end) end)

                   caught = assert_hostile(mode, catcher, fn -> with_hostile_kms(mode, fn -> Writer.write(@repo, a) end) end)
                   assert caught
                   assert @repo.in_transaction?()
                   assert events_with_detail(a.detail) == 0, "the #{mode} left an aud_event without its chain entry"
                   :carried_on
                 end)

        assert events_with_detail(a.detail) == 0
      end
    end

    defp assert_hostile(mode, catcher, fun) do
      outcome =
        try do
          fun.()
          :no_raise
        catch
          kind, reason -> {kind, reason}
        end

      assert {^catcher, _} = outcome, "the #{mode} adapter did not fire as a #{catcher}"
      true
    end

    test "RED: a caller whose transaction is already aborted gets {:error, :audit_chain_unavailable} and a report, not a raised 25P02" do
      a = attrs(%{detail: "aborted-#{System.unique_integer([:positive])}"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # the caller's transaction was aborted by its own failed statement: it stays aborted (the commit becomes a rollback)
          assert {:error, :rollback} =
                   @repo.transaction(fn ->
                     assert_raise Postgrex.Error, fn -> @repo.query!("SELECT 1/0") end
                     assert {:error, :audit_chain_unavailable} = Writer.write(@repo, a)
                     :answered
                   end)
        end)

      assert log =~ "write failed write=audit_chain_savepoint"
      assert events_with_detail(a.detail) == 0

      # control: the same write in a healthy transaction lands
      assert {:ok, {:ok, _}} = @repo.transaction(fn -> Writer.write(@repo, a) end)
      assert events_with_detail(a.detail) == 1
    end
  end
end
