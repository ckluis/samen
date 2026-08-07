defmodule Samen.Sequences do
  @moduledoc """
  The Outreach engine's shared logic (spec §I2, T75) — resource-module-agnostic
  (every host materializes its OWN `Sequence`/`Enrollment`/`StepSend` modules via
  `Samen.Scopes.Outreach`; this module operates on whatever struct/module it is
  handed, mirroring `Samen.Automation.ReminderFire`'s reload-by-id discipline).

  ## The due-scan pipeline (`handle_due/3`)

  Driven by `Enrollment`'s AshOban `:sequence_step_due` trigger (via the
  `:advance_due` action's inline change, `Samen.Scopes.Outreach.Blueprint`):

    1. **Reply check** (`Samen.Sequences.ReplyCheck`) — if the contact has replied
       since enrollment, the enrollment transitions straight to `:paused` /
       `:replied` and NOTHING is queued (spec I2 done-criterion 2). A reply-check
       that cannot answer (unavailable / raised) does NOT send this cycle either —
       it retries after a short backoff, never silently treated as "no reply".
    2. **Queue the due step** — otherwise, one `StepSend` row (`:queued`) is
       created for `enrollment.current_step` and
       `Samen.Sequences.SendWorker.enqueue/1` is called in the SAME transaction
       (`Oban.insert` inside the `:advance_due` action's `after_action`, the exact
       `Samen.Automation.EventCapture` idiom). `next_send_at` is cleared (the
       enrollment is "in flight" until the worker resolves the outcome) —
       `current_step` is NOT advanced yet (a step only advances once the C2
       chokepoint has genuinely confirmed it, `resolve_outcome/3`).

  ## The outcome pipeline (`resolve_outcome/3`)

  Called by `Samen.Sequences.SendWorker` AFTER `Samen.Delivery.Chokepoint.send/2`
  returns:

    * `{:ok, _receipt}` — advance to the next step (schedule `next_send_at` from
      its `delay_hours`) or `:completed` when no step remains.
    * `{:error, :suppressed}` — `:stopped` PERMANENTLY, `paused_reason:
      :suppressed` (spec I2 done-criterion 3). `current_step` is untouched — the
      step that was refused never counts as sent.
    * any other error (`:adapter_unconfigured` included — ADR-014 §3) — retry
      after a short backoff. `current_step` is untouched: a blocked/failed step
      NEVER fakes progress (Invariant D1, carried here unchanged).
  """

  require Ash.Query
  require Logger

  alias Samen.Sequences.ReplyCheck

  @retry_backoff_seconds 300

  # T75 fix round MED-2: the in-flight WATCHDOG window. While a step is queued
  # + an Oban delivery job is outstanding, `next_send_at` is set to "now +
  # this" (NEVER `nil`) — so if the worker crashes, the job silently
  # discards, or the enqueue itself never lands, the NEXT due-scan cycle
  # re-selects the enrollment and retries via `find_or_create_step_send/2`
  # (which REUSES the existing unresolved row rather than duplicating it).
  # Without this, an in-flight `next_send_at: nil` enrollment is unselectable
  # by the AshOban `where` clause FOREVER — a true permanent silent stall.
  @in_flight_watchdog_seconds 600

  @doc "The retry backoff (seconds) after a reply-check-unavailable or blocked/failed send."
  def retry_backoff_seconds, do: @retry_backoff_seconds

  @doc "The in-flight watchdog window (seconds) — see moduledoc / MED-2."
  def in_flight_watchdog_seconds, do: @in_flight_watchdog_seconds

  # ---------------------------------------------------------------------------
  # Enrollment initial state (called from Enrollment's :enroll action)

  @doc """
  Compute the `Enrollment` create attrs from a loaded `Sequence`. A sequence with
  NO steps enrolls straight to `:completed` (honest: there was nothing to send)
  rather than sitting `:active` with nothing ever due.
  """
  @spec initial_state(struct()) :: map()
  def initial_state(%{steps: steps}) when is_list(steps) and steps != [] do
    delay = steps |> List.first() |> Map.get("delay_hours", 0)
    ts = now()

    %{
      status: :active,
      current_step: 0,
      next_send_at: in_future(delay, :hours),
      enrolled_at: ts,
      completed_at: nil,
      # MED-4: the reply-detection cutoff starts equal to enrolled_at; :resume
      # is the ONLY thing that ever bumps it afterward.
      reply_cutoff_at: ts
    }
  end

  def initial_state(_no_steps) do
    ts = now()

    %{
      status: :completed,
      current_step: 0,
      next_send_at: nil,
      enrolled_at: ts,
      completed_at: ts,
      reply_cutoff_at: ts
    }
  end

  @doc "Fetch a same-org resource row by id, `authorize?: false` (system-context read)."
  @spec fetch(module(), String.t() | nil, String.t() | nil) :: {:ok, struct()} | {:error, term()}
  def fetch(_resource, nil, _org_id), do: {:error, :missing_id}

  def fetch(resource, id, org_id) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.filter(id == ^id and org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Fetch a resource row by its primary key ONLY, `authorize?: false`
  (system-context read; used by `Samen.Sequences.SendWorker`, which loads a
  `StepSend` before it even knows which org it belongs to). Safe: a primary-key
  lookup selects at most one row regardless of org.

  `org_id` is force-selected: `Samen.Transformers.CoreAttributes` injects it
  with `always_select?: false` (the SAME reason `Samen.Automation.ReminderFire`/
  `ScheduleAdvance` reload their own scan rows explicitly), so a bare `Ash.get/3`
  would otherwise hand the caller `%Ash.NotLoaded{}` for `org_id` — exactly the
  field `Samen.Sequences.SendWorker` needs to build the outbound `Message`.
  """
  @spec fetch_by_id(module(), String.t() | nil) :: {:ok, struct()} | {:error, term()}
  def fetch_by_id(_resource, nil), do: {:error, :missing_id}

  def fetch_by_id(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # T75 fix round MED-2: LOG LOUDLY (never a silent swallow) — a transient
    # DB blip here previously turned into a bare {:error, _} indistinguishable
    # from "row genuinely absent", and `Samen.Sequences.SendWorker.perform/1`
    # used to turn EITHER into a permanent `{:discard, _}` (see that module's
    # own MED-2 fix: the fetch-chain failure is now retriable, not discarded).
    e ->
      Logger.error(
        "[Samen.Sequences] fetch_by_id RAISED resource=#{inspect(resource)} id=#{inspect(id)}: " <>
          Exception.message(e)
      )

      {:error, Exception.message(e)}
  end

  @doc """
  Reload the fields `handle_due/3` needs. Mirrors `Samen.Automation.ReminderFire`'s
  reload-by-id: the AshOban due-scan's streamed record is only guaranteed to carry
  its primary key + whatever the trigger's `where` touched.
  """
  @spec reload(module(), String.t() | nil) :: struct() | nil
  def reload(_resource, nil), do: nil

  def reload(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([
      :id,
      :org_id,
      :sequence_id,
      :person_id,
      :current_step,
      :status,
      :enrolled_at,
      :reply_cutoff_at
    ])
    |> Ash.read!(authorize?: false)
    |> case do
      [row | _] -> row
      [] -> nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # The due-scan pipeline

  @spec handle_due(struct(), module(), module()) :: :ok
  def handle_due(enrollment, sequence_mod, step_send_mod) do
    # MED-4: reply_cutoff_at, NEVER enrolled_at — :resume bumps the former so a
    # reply-paused enrollment that has been explicitly resumed is not
    # immediately re-paused by the SAME stale reply.
    #
    # T75 closing round DELTA-2: `reply_cutoff_at` is a nullable column (no
    # default) — a row that predates this column (or one hand-nulled) must
    # not crash the due-scan (ReplyCheck.replied_since?/3 pattern-matches on
    # `%DateTime{}`). Fall back to `enrolled_at`, the cutoff's own original
    # value before MED-4 introduced the separate column.
    cutoff = enrollment.reply_cutoff_at || enrollment.enrolled_at

    case ReplyCheck.replied_since?(enrollment.org_id, enrollment.person_id, cutoff) do
      {:ok, true} ->
        transition(enrollment, %{status: :paused, paused_reason: :replied, next_send_at: nil})
        :ok

      {:ok, false} ->
        queue_step_send(enrollment, sequence_mod, step_send_mod)
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Samen.Sequences] reply check unavailable enrollment_id=#{enrollment.id} " <>
            "reason=#{inspect(reason)} — NOT sending this cycle, retrying later"
        )

        transition(enrollment, %{next_send_at: in_future(@retry_backoff_seconds, :seconds)})
        :ok
    end
  end

  defp queue_step_send(enrollment, sequence_mod, step_send_mod) do
    with {:ok, sequence} <- fetch(sequence_mod, enrollment.sequence_id, enrollment.org_id) do
      step = Enum.at(sequence.steps || [], enrollment.current_step)

      if is_nil(step) do
        # No step at this index (the sequence shrank underneath an in-flight
        # enrollment) — complete honestly rather than looping forever.
        transition(enrollment, %{status: :completed, next_send_at: nil, completed_at: now()})
      else
        case find_or_create_step_send(step_send_mod, enrollment) do
          {:ok, send_row} ->
            # In-flight: a WATCHDOG next_send_at (MED-2 — NEVER nil) so a
            # stalled/crashed worker still gets re-selected + retried by the
            # next due-scan cycle. current_step stays put — it only advances
            # once resolve_outcome/3 sees a genuine chokepoint outcome.
            transition(enrollment, %{next_send_at: in_future(@in_flight_watchdog_seconds, :seconds)})
            enqueue_send(enrollment, send_row)

          {:error, reason} ->
            Logger.warning(
              "[Samen.Sequences] StepSend queue failed enrollment_id=#{enrollment.id} " <>
                "reason=#{inspect(reason)} — retrying later"
            )

            transition(enrollment, %{next_send_at: in_future(@retry_backoff_seconds, :seconds)})
        end
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[Samen.Sequences] sequence lookup failed enrollment_id=#{enrollment.id} " <>
            "reason=#{inspect(reason)} — retrying later"
        )

        transition(enrollment, %{next_send_at: in_future(@retry_backoff_seconds, :seconds)})
    end
  end

  # T75 fix round MED-2 door 2: the Oban.insert return is no longer discarded.
  # A failed enqueue is LOGGED LOUDLY (never silent) — the watchdog window set
  # by the caller just above still guarantees recovery (the next due-scan
  # cycle re-attempts via find_or_create_step_send/2's REUSE path), but a
  # human should see this in logs immediately rather than only after the
  # watchdog window elapses.
  defp enqueue_send(enrollment, send_row) do
    case Samen.Sequences.SendWorker.enqueue(send_row.id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Samen.Sequences] SendWorker enqueue FAILED enrollment_id=#{enrollment.id} " <>
            "step_send_id=#{send_row.id} reason=#{inspect(reason)} — the next due-scan " <>
            "watchdog cycle will retry (find_or_create_step_send/2 reuses this SAME row)"
        )

        :ok
    end
  end

  # T75 fix round MED-2/MED-5: reuse (never duplicate) the StepSend row for
  # THIS `(enrollment_id, current_step)` across retry/watchdog cycles — this
  # is what makes the watchdog recovery loop safe (no new row per stall/retry)
  # AND what stops the "blocked forever" row flood (one row, updated in place,
  # not ~288/day).
  defp find_or_create_step_send(step_send_mod, enrollment) do
    case existing_step_send(step_send_mod, enrollment) do
      {:ok, %{status: status} = row} when status in [:queued, :blocked, :failed] ->
        requeue_step_send(row)

      {:ok, resolved_row} ->
        # Defensive: a row for this step already reached a terminal outcome
        # (:delivered/:suppressed/:skipped) but the enrollment's current_step
        # was never advanced past it — an inconsistency that should not arise
        # given resolve_outcome/3 always advances current_step together with
        # writing the terminal StepSend status, but fail LOUDLY + safely
        # (create a fresh row) rather than silently reusing a resolved row's
        # identity.
        Logger.warning(
          "[Samen.Sequences] found an ALREADY-RESOLVED StepSend " <>
            "(id=#{resolved_row.id}, status=#{resolved_row.status}) for the CURRENT step " <>
            "enrollment_id=#{enrollment.id} step_index=#{enrollment.current_step} — " <>
            "creating a fresh row rather than reusing it"
        )

        create_step_send(step_send_mod, enrollment)

      {:error, :not_found} ->
        create_step_send(step_send_mod, enrollment)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_step_send(step_send_mod, enrollment) do
    step_send_mod
    |> Ash.Query.filter(enrollment_id == ^enrollment.id and step_index == ^enrollment.current_step)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "[Samen.Sequences] existing_step_send RAISED enrollment_id=#{enrollment.id}: " <>
          Exception.message(e)
      )

      {:error, Exception.message(e)}
  end

  defp requeue_step_send(row) do
    row
    |> Ash.Changeset.for_update(:requeue, %{}, authorize?: false)
    |> Ash.update()
  end

  defp create_step_send(step_send_mod, enrollment) do
    step_send_mod
    |> Ash.Changeset.for_create(
      :queue,
      %{org_id: enrollment.org_id, enrollment_id: enrollment.id, step_index: enrollment.current_step},
      authorize?: false
    )
    |> Ash.create()
  end

  # ---------------------------------------------------------------------------
  # The outcome pipeline (called by Samen.Sequences.SendWorker)

  @spec resolve_outcome(struct(), struct(), {:ok, map()} | {:error, term()}) :: :ok
  def resolve_outcome(enrollment, sequence, {:ok, _receipt}) do
    next_step = enrollment.current_step + 1
    steps = sequence.steps || []

    attrs =
      if next_step < length(steps) do
        delay = steps |> Enum.at(next_step) |> Map.get("delay_hours", 0)
        %{current_step: next_step, status: :active, next_send_at: in_future(delay, :hours)}
      else
        %{current_step: next_step, status: :completed, next_send_at: nil, completed_at: now()}
      end

    transition(enrollment, attrs)
    :ok
  end

  def resolve_outcome(enrollment, _sequence, {:error, :suppressed}) do
    transition(enrollment, %{status: :stopped, paused_reason: :suppressed, next_send_at: nil})
    :ok
  end

  # T75 fix round MED-5: :adapter_unconfigured is a KNOWN-PERMANENT condition
  # (no ESP wired — it will not fix itself without operator action), unlike a
  # generic transient provider failure. The enrollment surfaces this HONESTLY
  # as `status: :blocked` — no longer indistinguishable from a healthy
  # `:active` enrollment. Still due-scan-eligible (the AshOban `where` clause
  # includes `:blocked`), so the instant an adapter is configured the very
  # next successful send flips it back to `:active`/`:completed` for free
  # (the `{:ok, _receipt}` clause above sets status unconditionally).
  def resolve_outcome(enrollment, _sequence, {:error, :adapter_unconfigured}) do
    transition(enrollment, %{status: :blocked, next_send_at: in_future(@retry_backoff_seconds, :seconds)})
    :ok
  end

  def resolve_outcome(enrollment, _sequence, {:error, _other}) do
    # Any other provider failure: current_step is untouched, so a failed step
    # is retried, never silently advanced past. Status is left AS-IS
    # (transition/2 only writes the attrs given — omitting :status here means
    # a transient failure on an :active enrollment stays :active; on an
    # already-:blocked enrollment it stays :blocked).
    transition(enrollment, %{next_send_at: in_future(@retry_backoff_seconds, :seconds)})
    :ok
  end

  @doc false
  @spec transition(struct(), map()) :: {:ok, struct()} | {:error, term()}
  def transition(enrollment, attrs) do
    enrollment
    |> Ash.Changeset.for_update(:system_advance, attrs, authorize?: false)
    |> Ash.update()
  rescue
    e ->
      Logger.warning(
        "[Samen.Sequences] transition raised enrollment_id=#{Map.get(enrollment, :id)}: " <>
          Exception.message(e)
      )

      {:error, e}
  end

  defp in_future(n, :hours), do: DateTime.utc_now() |> DateTime.add(n * 3600, :second) |> DateTime.truncate(:second)
  defp in_future(n, :seconds), do: DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.truncate(:second)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
