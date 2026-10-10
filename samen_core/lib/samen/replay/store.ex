defmodule Samen.Replay.Store do
  @moduledoc """
  Persists a finished capture session (ADR-052 §2.2 rule 4): one `Samen.Replay.Session` row and
  its `Samen.Replay.Frame` rows, in ONE transaction, after encoding every frame and validating
  it against `Samen.Replay.FrameSchema`. A frame that fails validation is NOT stored (it is
  counted in `rejected_count`); a session never half-persists.

  Runs in the monitor's task, never in the LiveView process.
  """

  require Logger

  alias Samen.Replay.{FrameSchema, Frame, Session}

  @doc """
  Persist `meta` + buffered `frames` (+ a final `:exit` frame). `counters` carries
  `:bytes`, `:interactions`, `:truncated`, `:exit_reason`. Returns `{:ok, session}` or
  `{:error, kind}` with a bounded kind.
  """
  @spec persist(map(), list(), map()) :: {:ok, struct()} | {:error, atom()}
  def persist(meta, frames, counters) do
    exit_frame = {next_seq(frames), at_ms(meta), :exit, %{reason: counters.exit_reason}}

    {valid, rejected} =
      (frames ++ [exit_frame])
      |> Enum.map(&FrameSchema.encode/1)
      |> Enum.split_with(&(FrameSchema.validate(&1) == :ok))

    repo = AshPostgres.DataLayer.Info.repo(Session, :mutate)

    result =
      repo.transaction(fn ->
        session =
          Session
          |> Ash.Changeset.for_create(:record, session_attrs(meta, counters, valid, rejected))
          |> Ash.create!(authorize?: false)

        rows =
          Enum.map(valid, fn f ->
            %{
              org_id: meta.org_id,
              session_id: session.id,
              seq: f.seq,
              kind: f.kind,
              at_ms: f.at_ms,
              payload: f.payload
            }
          end)

        %Ash.BulkResult{status: :success} =
          Ash.bulk_create(rows, Frame, :record,
            authorize?: false,
            return_errors?: true,
            stop_on_error?: true
          )

        session
      end)

    case result do
      {:ok, session} -> {:ok, session}
      {:error, _} -> {:error, :persist_failed}
    end
  rescue
    e -> {:error, error_kind(e)}
  end

  defp session_attrs(meta, counters, valid, rejected) do
    %{
      org_id: meta.org_id,
      actor_ref: meta.actor_ref,
      view: meta.view,
      view_md5: meta.view_md5,
      started_at: meta.started_at,
      ended_at: DateTime.utc_now(),
      exit_reason: counters.exit_reason,
      frame_count: length(valid),
      byte_count: counters.bytes,
      interaction_count: counters.interactions,
      rejected_count: length(rejected),
      truncated: counters.truncated
    }
  end

  defp next_seq([]), do: 1
  defp next_seq(frames), do: (frames |> List.last() |> elem(0)) + 1

  defp at_ms(%{started_mono: t0}) when is_integer(t0),
    do: max(System.monotonic_time(:millisecond) - t0, 0)

  defp at_ms(_), do: 0

  # The exception MODULE only — an exception message can carry the value being written.
  defp error_kind(%{__struct__: mod}) when is_atom(mod) do
    Logger.error("[Samen.Replay.Store] persist raised #{inspect(mod)}")
    :persist_raised
  end
end
