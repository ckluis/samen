defmodule Samen.Web.Reads.Adoption do
  @moduledoc """
  A STRUCTURAL answer to "is this optional feature adopted on this host?" — used after a read of
  an optional table FAILED, to decide between the documented honest empty ("this host never
  adopted it") and an outage ("it is adopted, and broken").

  The question used to be answered by string-matching the exception text ("could not lookup Ecto
  repo", "undefined_table"), so a repo that was down or restarting, or a migration that was never
  run on a host that HAD adopted the feature, rendered the honest empty and logged nothing. Here the
  answer is decided from facts, never from error text:

    1. Resolve the repo (`AshPostgres.DataLayer.Info.repo/2` for an Ash resource, or the repo the
       caller names for an Ecto schema).
    2. Is it STARTED (its process is registered)? If not: is it CONFIGURED on this host (listed in
       some loaded application's `:ecto_repos`)? Configured-but-not-running is a repo that is
       DOWN or restarting — `:repo_down`; never configured is `:not_adopted`.
    3. Started: does the table exist (`to_regclass`)? No: `:table_missing`.
    4. Otherwise `:ready` — the failure was something else, and the caller treats it as a failure.

  Nothing is cached. A transient `:repo_down` must never be remembered as "not adopted", and the
  probe only runs after a read has already failed, so it costs nothing on the healthy path.

  Callers decide what each state means for THEIR feature:

    * a feature a host must opt into by pointing a repo at it (the AI draft domain): only
      `:not_adopted` is the honest empty; `:repo_down`, `:table_missing`, `:ready` and `:unknown`
      are failures;
    * a table that a minimal host legitimately lacks while its repo is fine (impersonation
      sessions): `:not_adopted` and `:table_missing` are the honest empty.

  `:unknown` means the probe itself could not decide (it is reported by name and exception module
  and must be treated as a failure).
  """

  require Logger

  alias Samen.Web.Reads.Guard

  @type state :: :ready | :not_adopted | :repo_down | :table_missing | :unknown

  @doc "Probe an Ash resource backed by AshPostgres."
  @spec probe_resource(module()) :: state()
  def probe_resource(resource) when is_atom(resource) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :read)
    table = AshPostgres.DataLayer.Info.table(resource)
    schema = AshPostgres.DataLayer.Info.schema(resource)
    probe(repo, table, schema)
  rescue
    e ->
      Guard.report(:adoption_probe, nil, e)
      :unknown
  end

  @doc "Probe `table` (optionally in `schema`) on `repo`."
  @spec probe(module() | nil, String.t() | nil, String.t() | nil) :: state()
  def probe(repo, table, schema \\ nil)

  def probe(nil, _table, _schema), do: :not_adopted

  def probe(repo, table, schema) when is_atom(repo) and is_binary(table) do
    cond do
      started?(repo) -> table_state(repo, qualified(table, schema))
      configured?(repo) -> :repo_down
      true -> :not_adopted
    end
  rescue
    e ->
      Guard.report(:adoption_probe, nil, e)
      :unknown
  end

  @doc """
  Log, ONCE per node per resource, that a feature reads as not adopted (so an operator who expected
  it can see why a screen is empty). Idempotent and cheap; carries the resource name only.
  """
  @spec log_not_adopted_once(module()) :: :ok
  def log_not_adopted_once(resource) when is_atom(resource) do
    key = {__MODULE__, :logged, resource}

    if :persistent_term.get(key, false) do
      :ok
    else
      :persistent_term.put(key, true)

      Logger.warning(
        "[Samen.Web.Reads] feature not adopted on this host resource=#{inspect(resource)} — reads answer the honest empty"
      )
    end
  end

  @doc false
  def forget_logged(resource), do: :persistent_term.erase({__MODULE__, :logged, resource})

  # -- facts ---------------------------------------------------------------------------------

  defp started?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :get_dynamic_repo, 0) and
      GenServer.whereis(repo.get_dynamic_repo()) != nil
  end

  defp configured?(repo) do
    Enum.any?(Application.loaded_applications(), fn {app, _, _} ->
      repo in List.wrap(Application.get_env(app, :ecto_repos, []))
    end)
  end

  defp table_state(repo, name) do
    case repo.query("SELECT to_regclass($1)::text", [name]) do
      {:ok, %{rows: [[nil]]}} -> :table_missing
      {:ok, %{rows: [[_found]]}} -> :ready
      {:error, error} ->
        Guard.report(:adoption_probe, nil, error)
        :unknown
    end
  end

  defp qualified(table, nil), do: table
  defp qualified(table, schema), do: ~s("#{schema}"."#{table}")
end
