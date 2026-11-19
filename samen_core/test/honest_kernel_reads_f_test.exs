defmodule Samen.HonestKernelReadsFTest do
  @moduledoc """
  Honest reads, kernel phase F. A read that FAILED must not read as a harmless value. Every RED injects a real failure
  (a table the read depends on that is genuinely gone, an unreadable key) and pairs with a positive control through the
  same seam; every report is value-free (names and exception modules only).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.AI.Agent.Breaker
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    :ok
  end

  # Take a table away INSIDE the test's sandbox transaction (DDL is transactional in Postgres, rolled back at the
  # end of the test): every read of it then fails with a real `undefined_table` database error.
  defp hide_table!(table), do: Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_hidden_by_test")

  describe "agent Breaker.check_start/2: a run log that cannot be counted is not 'under the rate limit'" do
    test "RED: an uncountable run log refuses the start {:error, :unavailable}, trips nothing, reports by name; healthy control starts" do
      org = Ash.UUID.generate()

      # POSITIVE CONTROL: the count works and is under the limit
      assert :ok = Breaker.check_start(org, "f.agent")

      hide_table!("ai_agent_run")

      raw =
        try do
          Ash.count!(Samen.AI.Agent.Run, authorize?: false)
        rescue
          e -> Exception.message(e)
        end

      assert raw =~ "ai_agent_run", "the injected failure must be a real undefined_table error naming the table"

      log = capture_log(fn -> assert {:error, :unavailable} = Breaker.check_start(org, "f.agent") end)

      assert log =~ "read=breaker_rate_count"
      refute log =~ "ai_agent_run"
      assert Breaker.kills(org) == [], "an unreadable count must not trip the kill"
    end
  end
end
