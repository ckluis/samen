defmodule Samen.Automation.Remind do
  @moduledoc """
  The E4 reminder scheduler public API (ADR-039 §6.1 — binding signatures; T40's
  `enqueue_reminder` action builds directly on this). Host-wired seam, the
  `Notifications.Engine`/`Samen.Automation` convention:

      config :samen_core, Samen.Automation.Remind,
        reminder_module: Demo.AutomationScope.Reminder,
        repo: Demo.Repo

  `opts` carries the host module/repo overrides (a test/caller override; opts win
  over config). Unwired ⇒ fail-closed `{:error, :no_automation_module}` — a caller
  that explicitly asks to schedule/snooze/cancel a reminder gets an honest
  failure, never a silent drop.
  """

  @doc """
  Schedule a reminder. `attrs`: `%{org_id: id, recipient_id: id, subject_ref:
  String.t(), remind_at: DateTime.t(), note: String.t() | nil, source: :user |
  :automation | :system}`.
  """
  @spec schedule(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def schedule(attrs, opts \\ []) do
    with {:ok, {res, _repo}} <- wiring(opts) do
      create_attrs =
        %{
          org_id: fetch(attrs, :org_id),
          recipient_id: fetch(attrs, :recipient_id),
          subject_ref: fetch(attrs, :subject_ref),
          remind_at: fetch(attrs, :remind_at),
          note: fetch(attrs, :note),
          source: fetch(attrs, :source) || :user
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      res
      |> Ash.Changeset.for_create(:schedule, create_attrs, authorize?: false)
      |> Ash.create()
    end
  end

  @doc """
  Snooze `reminder_id` — updates `remind_at` in place (the row stays the SAME
  future intent, per §6.2). Governed by `actor`'s own policies (org-scoped).
  """
  @spec snooze(term(), DateTime.t(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def snooze(reminder_id, %DateTime{} = until, actor, opts \\ []) do
    with {:ok, {res, _repo}} <- wiring(opts),
         {:ok, reminder} <- fetch_reminder(res, reminder_id, actor) do
      reminder
      |> Ash.Changeset.for_update(:snooze, %{remind_at: until}, actor: actor)
      |> Ash.update()
    end
  end

  @doc "Cancel `reminder_id`. Governed by `actor`'s own policies (org-scoped)."
  @spec cancel(term(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def cancel(reminder_id, actor, opts \\ []) do
    with {:ok, {res, _repo}} <- wiring(opts),
         {:ok, reminder} <- fetch_reminder(res, reminder_id, actor) do
      reminder
      |> Ash.Changeset.for_update(:cancel, %{}, actor: actor)
      |> Ash.update()
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_reminder(res, id, actor) do
    case Ash.get(res, id, actor: actor) do
      {:ok, reminder} -> {:ok, reminder}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @spec wiring(keyword()) :: {:ok, {module(), module()}} | {:error, :no_automation_module}
  defp wiring(opts) do
    res = opt(opts, :reminder_module)
    repo = opt(opts, :repo) || res_repo(res)

    cond do
      is_nil(res) -> {:error, :no_automation_module}
      is_nil(repo) -> {:error, :no_automation_module}
      true -> {:ok, {res, repo}}
    end
  end

  defp res_repo(nil), do: nil

  defp res_repo(res) do
    AshPostgres.DataLayer.Info.repo(res)
  rescue
    _ -> nil
  end

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end
