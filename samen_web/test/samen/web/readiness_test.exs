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
end
