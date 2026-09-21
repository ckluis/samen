defmodule Samen.Delivery.ThrottleSnoozeIsolationStubAdapter do
  @moduledoc """
  Minimal adapter double, deliberately defined LOCALLY rather than reused from
  `Samen.Delivery.ThrottleSnoozeStubAdapter` (`throttle_snooze_test.exs`) —
  cross-file test module availability depends on which files a given `mix
  test` invocation compiles, and this file must reproduce the mechanism
  standalone.
  """
  use Samen.Delivery.Provider

  @impl true
  def configured?(_config), do: true

  @impl true
  def deliver(_message, config) do
    Map.get(config, :canned_response, {:ok, %{provider_message_id: "stub-1"}})
  end
end

defmodule Samen.Delivery.ThrottleSnoozeIsolationTest do
  @moduledoc """
  Issue #45 regression guard — the exact isolation bug in
  `Samen.Delivery.ThrottleSnoozeTest`, reproduced directly so it can never come
  back unnoticed.

  ## The mechanism

  `Samen.Scopes.Marketing.SendWorker`'s `:adapter_unconfigured` arm
  (`mark_blocked/2` -> `emit_blocked_audit/2`) writes the job's `send_id`
  straight into `aud_event.aud_subject_id` via `Samen.AuditEvent.insert/2` — a
  plain TEXT column (`aud_subject_id TEXT`, no CHECK constraint) with NO format
  validation anywhere in the write path: `Samen.AuditEvent.insert/2`'s
  changeset only casts `:subject_id` as a string, and
  `Samen.Delivery.Message.from_args/1` only checks that `send_id` is PRESENT,
  never that it is a UUID. Every OTHER `samen_core` test that touches Postgres
  takes an `Ecto.Adapters.SQL.Sandbox.checkout/1` in `setup` (see
  `test/retention_sweep_test.exs`, `test/feature_flags_engine_test.exs`, …) so
  its writes roll back with the test. `ThrottleSnoozeTest` (PR #28) did not —
  so a worker call there that reaches `emit_blocked_audit/2` over a connection
  NOT wrapped in a per-test sandbox transaction genuinely commits its
  (deliberately non-UUID) test `send_id` ("s1"/"s2"/"s3"), which outlives the
  test.

  That row then poisons `Samen.Rollup.refresh/2`: the `daily_event_count`
  rollup spec (`config/config.exs`) casts `aud_subject_id::uuid` —
  `ERROR 22P02 invalid input syntax for type uuid: "s2"` — failing every later
  test in that run that rebuilds rollups (14–17 tests: `PostShredOracleTest`,
  `ErasureTest`, `RollupTest`, `RetentionSweepTest`, `AI.AgentFoldSourceTest`).

  ## Why an INDEPENDENT reader connection, not "check after the test ends"

  Reading `aud_event` back on the SAME connection that just wrote it would see
  its own uncommitted work either way (ordinary "read your own writes") and
  prove nothing about survival. The only thing that distinguishes "rolled back
  with this test" from "genuinely committed" is a SEPARATE Postgres session:
  under the default READ COMMITTED isolation, a second connection can never
  see another session's still-open (sandboxed) transaction — so if the write
  went through the checkout above, an independent reader sees nothing, full
  stop, no timing/ordering involved. If the write instead escaped the sandbox
  (no checkout, or one bypassed as `sandbox: false`), it is genuinely
  auto-committed the instant it happens, and the SAME independent reader sees
  it immediately. A `Task` gives us that second, distinct connection cheaply,
  entirely within this one test — no dependency on `mix test` seed, test
  order, or process-exit timing.

  ## Why this reproduces the bug directly rather than "just omit the checkout"

  Under `test_helper.exs`'s default `Ecto.Adapters.SQL.Sandbox.mode(TestRepo,
  :manual)`, a write from a process that never checked out simply raises
  `DBConnection.OwnershipError` — which `emit_blocked_audit/2` SILENTLY
  RESCUES (`rescue _ -> :ok`), so nothing is ever written. That is exactly why
  issue #45 is "a real race, not seed-bound": it only bites when the
  connection is genuinely NOT sandbox-isolated for this process — the state
  `Ecto.Adapters.SQL.Sandbox.checkout(repo, sandbox: false)` deliberately
  creates (the documented Ecto escape hatch for a real, non-rollback
  connection), and the state a suite can transiently fall into via an
  unrelated timing race. This test reproduces THAT state directly and
  deterministically, entirely locally (no effect on any other test's
  connection), rather than depending on winning an actual race.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Samen.AuditEvent
  alias Samen.Delivery.ThrottleSnoozeIsolationStubAdapter, as: Stub
  alias Samen.Scopes.Marketing.SendWorker
  alias SamenCore.TestRepo

  setup do
    previous = Application.get_env(:samen_core, SendWorker)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:samen_core, SendWorker)
        value -> Application.put_env(:samen_core, SendWorker, value)
      end
    end)

    :ok
  end

  test "a blocked-audit write never survives this test — no non-UUID aud_subject_id row leaks (issue #45)" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

    subject_id = "iso-#{System.unique_integer([:positive])}"

    Application.put_env(:samen_core, SendWorker,
      adapter: Stub,
      adapter_config: %{canned_response: {:error, :adapter_unconfigured}}
    )

    assert {:error, :adapter_unconfigured} =
             SendWorker.perform(%Oban.Job{args: %{"send_id" => subject_id, "org_id" => nil}})

    # An INDEPENDENT reader connection (its own Postgres session, via a
    # separate process) — see the moduledoc for why this, and not the same
    # connection, is what proves survival.
    leaked =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)
        rows = TestRepo.all(from(a in AuditEvent, where: a.subject_id == ^subject_id))
        Ecto.Adapters.SQL.Sandbox.checkin(TestRepo)
        rows
      end)
      |> Task.await()

    assert leaked == [],
           "a non-UUID aud_subject_id row (#{inspect(leaked)}) is visible to an INDEPENDENT " <>
             "connection while this test is still running — the write escaped the sandbox " <>
             "(the exact throttle_snooze_test.exs omission, issue #45) instead of staying " <>
             "inside this test's own, still-open transaction"
  end
end
