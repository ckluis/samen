defmodule Samen.Web.Readiness do
  @moduledoc """
  The READINESS probe backing the generated app's `GET /readyz` (WS-F1 / F1.2).

  `/healthz` is LIVENESS only — it proves the BEAM is up and can send a response;
  it says nothing about whether the app can actually serve a governed request.
  Fly's `[[http_service.checks]]` GATES TRAFFIC on its check, so a static-200
  `/healthz` behind that gate sends live traffic to a machine whose Postgres, KMS
  wrapped-DEK store, or Oban queue is unreachable — every real request then 500s.

  `check/1` is the readiness signal: it probes the three dependencies a Samen app
  cannot serve a governed request without —

    * `:repo` — `SELECT 1` round-trips the app Postgres (data + queue + audit + catalog).
    * `:kms`  — the configured `Samen.Kms` adapter answers a cheap, READ-ONLY `attest/1`
                probe, proving the external wrapped-DEK store is reachable (no store →
                no vault decrypt → no governed read).
    * `:oban` — the Oban instance is running (durable jobs/cron/workflows are Postgres rows).

  It returns `{:ok, checks}` only when ALL THREE answer; otherwise `{:error, checks}`,
  where `checks` is a keyword list of `component => :ok | {:error, reason}` so the
  endpoint can report WHICH dependency is down — a 503, never a false 200.

  FAIL-CLOSED: any component that raises, exits, or times out is `{:error, _}`,
  never silently treated as ready.
  """

  # A subject id that never exists — `attest/1` on it is a pure READ that proves the
  # wrapped-DEK store answered, without minting, unwrapping, or mutating any key.
  @kms_probe_subject "__samen_readiness_probe__"

  @type component :: :repo | :kms | :oban
  @type status :: :ok | {:error, term()}

  @spec check(keyword()) ::
          {:ok, [{component(), status()}]} | {:error, [{component(), status()}]}
  def check(opts) do
    repo = Keyword.fetch!(opts, :repo)
    oban = Keyword.get(opts, :oban, Oban)

    checks = [repo: check_repo(repo), kms: check_kms(), oban: check_oban(oban)]

    if Enum.all?(checks, fn {_component, status} -> status == :ok end),
      do: {:ok, checks},
      else: {:error, checks}
  end

  defp check_repo(repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp check_kms do
    adapter = Samen.Kms.adapter()

    case adapter.attest(@kms_probe_subject) do
      # The store answered (absent/active/shredded are all "reachable").
      {:ok, _attestation} -> :ok
      # The adapter reports its store as unreachable — NOT ready.
      {:error, :unavailable} -> {:error, :unavailable}
      # Any other definitive answer still proves the store responded.
      {:error, _definitive} -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp check_oban(oban) do
    _config = Oban.config(oban)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end
end
