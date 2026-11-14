defmodule Samen.Web.ReadinessTest do
  @moduledoc """
  Red-path proofs for `Samen.Web.Readiness` (WS-F1 / F1.2) — the readiness probe
  behind the generated app's `GET /readyz`, which Fly's traffic gate rides.

  The contract under test: `check/1` returns `{:ok, checks}` ONLY when all three
  dependencies answer, and `{:error, checks}` — a 503, never a false 200 — the moment
  ANY of Postgres / the KMS wrapped-DEK store / Oban is unreachable. Each red path is
  paired with a POSITIVE CONTROL (the other two components stay `:ok`), so a blanket
  fail cannot masquerade as a discriminating one (anti-tautology).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Readiness

  # A KMS adapter whose wrapped-DEK store is UNREACHABLE — the fail-closed control.
  defmodule DownKms do
    @moduledoc false
    def attest(_subject), do: {:error, :unavailable}
  end

  setup do
    # Green KMS control: the in-memory adapter auto-starts and answers a read-only attest.
    prev_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.InMemory)

    on_exit(fn ->
      if prev_kms do
        Application.put_env(:samen_core, :kms_adapter, prev_kms)
      else
        Application.delete_env(:samen_core, :kms_adapter)
      end
    end)

    # Green Oban control: a running instance sharing the sandbox repo (no queues/plugins).
    _pid =
      start_supervised!(
        {Oban, repo: Repo, testing: :manual, plugins: false, name: __MODULE__.Oban}
      )

    %{oban: __MODULE__.Oban}
  end

  describe "green: every dependency answers" do
    test "check/1 returns {:ok, ...} with all three components :ok", %{oban: oban} do
      assert {:ok, checks} = Readiness.check(repo: Repo, oban: oban)
      assert checks[:repo] == :ok
      assert checks[:kms] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: Postgres unreachable" do
    test "repo down flips {:ok}→{:error}; kms + oban stay :ok (positive control)", %{oban: oban} do
      # A never-started repo — `Ecto.Adapters.SQL.query/3` raises on lookup; check fails closed.
      assert {:error, checks} = Readiness.check(repo: Samen.Web.ReadinessTest.PhantomRepo, oban: oban)
      assert match?({:error, _}, checks[:repo])
      # Anti-tautology: the OTHER probes still passed — the failure is discriminating.
      assert checks[:kms] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: KMS wrapped-DEK store unreachable" do
    test "kms :unavailable flips {:ok}→{:error}; repo + oban stay :ok (positive control)", %{oban: oban} do
      Application.put_env(:samen_core, :kms_adapter, DownKms)

      assert {:error, checks} = Readiness.check(repo: Repo, oban: oban)
      assert match?({:error, _}, checks[:kms])
      assert checks[:repo] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: Oban not running" do
    test "oban down flips {:ok}→{:error}; repo + kms stay :ok (positive control)" do
      # An Oban instance that was never started — `Oban.config/1` raises; check fails closed.
      assert {:error, checks} = Readiness.check(repo: Repo, oban: :samen_readiness_no_such_oban)
      assert match?({:error, _}, checks[:oban])
      assert checks[:repo] == :ok
      assert checks[:kms] == :ok
    end
  end

  # A repo whose catalog cannot be read.
  defmodule BlindRepo do
    def query(_sql, _params \\ []), do: {:error, %DBConnection.ConnectionError{message: "down"}}
  end

  describe "advisories: the audit-partition runway (ARCH-9) never takes the node out of rotation" do
    test "healthy: :ok, and the body is exactly `ready`", %{oban: oban} do
      Repo.query!("TRUNCATE aud_event_default")
      assert [partitions: :ok] = Readiness.advisories(repo: Repo)
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "rows in DEFAULT: a WARNING line in a 200 body (not a 503); positive control above", %{oban: oban} do
      Repo.query!("TRUNCATE aud_event_default")
      {:ok, _} = Samen.AuditEvent.insert(Repo, %{event_type: "system", occurred_at: ~U[2099-01-01 00:00:00Z]})

      assert [partitions: {:warn, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "default_rows=1"

      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "ready\npartitions: WARN aud_event: runway_days="
    end

    test "no partition covers now: CRITICAL, still a 200", %{oban: oban} do
      # every partition dropped but the DEFAULT: runway is behind us
      %{rows: rows} =
        Repo.query!(
          "SELECT c.relname FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent " <>
            "JOIN pg_class c ON c.oid = i.inhrelid WHERE p.relname = 'aud_event' AND c.relname <> 'aud_event_default'"
        )

      for [name] <- rows, do: Repo.query!("DROP TABLE #{name}")

      assert [partitions: {:critical, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "runway_critical"
      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "partitions: CRITICAL"
    end

    test "unreadable runway is UNKNOWN, never :ok (and an unreachable catalog does not crash the probe)" do
      assert [partitions: {:unknown, detail}] = Readiness.advisories(repo: BlindRepo)
      assert detail =~ "DBConnection.ConnectionError"
      refute detail =~ "down"

      assert [partitions: {:unknown, _}] = Readiness.advisories(repo: Samen.Web.ReadinessTest.PhantomRepo)
    end

    test "a dependency failure is still a 503, advisory lines appended", %{oban: _oban} do
      assert {503, body} = Readiness.report(repo: Repo, oban: :samen_readiness_no_such_oban)
      assert body =~ "not ready\n"
      assert body =~ "oban: FAIL"
    end
  end
end
