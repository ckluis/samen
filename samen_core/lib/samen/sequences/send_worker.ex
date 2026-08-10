defmodule Samen.Sequences.SendWorker do
  @moduledoc """
  Oban worker for sequence step delivery — **fail-honest** (ADR-014 §3), routed
  EXCLUSIVELY through the C2 chokepoint (T28), mirroring
  `Samen.Scopes.Marketing.SendWorker` line for line: the AshOban `:advance_due`
  action (`Samen.Scopes.Outreach.Blueprint`) only marks a `StepSend` `:queued`
  and enqueues this worker — the SLOW `Samen.Delivery.Chokepoint.send/2` call
  (network I/O) never runs inside that action's DB transaction, exactly why
  Marketing/Lifecycle split "queue" from "deliver" the same way.

  ## Job args convention (token-only — F2.1)

  Job args carry ONLY the `StepSend` row's opaque id — every other reference
  (org, enrollment, sequence, step content) is loaded from the resources this
  worker is configured with, never serialized into `oban_jobs.args`.

  ## Configuration

      config :samen_core, Samen.Sequences.SendWorker,
        sequence_resource: MyApp.Outreach.Sequence,
        enrollment_resource: MyApp.Outreach.Enrollment,
        step_send_resource: MyApp.Outreach.StepSend,
        adapter: MyApp.SendAdapter,             # optional legacy fallback
        adapter_config: %{...}

  Mirrors `Samen.Scopes.Marketing.SendWorker`'s config resolution: absent
  `:adapter` falls back to `Samen.Delivery.LocalSink` in `:test` env (honest
  capture) and to `nil` (⇒ `:adapter_unconfigured` ⇒ `StepSend.status ==
  :blocked`) in any other env. `Samen.Delivery.Chokepoint.send/2` ALSO consults
  `Samen.Delivery.ProviderSelection` first — a host with a real ESP wired via
  the host-default/per-org-override path needs no `:adapter` here at all.

  ## Fail-honest delivery (Invariant D1, unchanged)

  `perform/1` never marks a `StepSend` `:delivered` unless a CONFIGURED adapter
  genuinely returned `{:ok, _}`. Suppressed => `:suppressed` (the enrollment
  stops PERMANENTLY, `Samen.Sequences.resolve_outcome/3`). Unconfigured/failed
  => `:blocked` / `:failed` (the enrollment retries; `current_step` never
  advances past an unsent step).

  ## At-least-once, not exactly-once (Phase-6 EDGE-LOW L8, documented)

  If the adapter genuinely sends (`{:ok, receipt}`) but the FOLLOW-ON write —
  `mark/4`'s `StepSend` update AND/OR `Sequences.resolve_outcome/3`'s
  enrollment `current_step` advance — fails to persist (a correlated DB blip
  hitting both writes in the same `perform/1` call), the `StepSend` row is left
  non-terminal on the SAME step. `find_or_create_step_send/2`'s REUSE branch
  (`Samen.Sequences`) then legitimately re-selects that SAME row on the next
  in-flight-watchdog cycle and re-delivers — a genuine, honest **duplicate
  send**, not a lie (D1 still holds: `:delivered` is never faked, and this really
  IS a second real send). This is deliberately at-least-once, never silently
  claimed exactly-once.

  This is bounded, not a runaway loop: the moment a retry's mark+transition
  writes DO persist, the row/enrollment reach a terminal state and the
  watchdog stops re-selecting it.

  There is no per-adapter idempotency key negotiated over the wire today, but
  the idempotency key any real ESP adapter needs is already threaded through
  on every attempt for free: `message.send_id` (`Samen.Delivery.Message`) is
  the `StepSend` row's OWN id, which `find_or_create_step_send/2` REUSES
  (never re-mints) across every retry/watchdog cycle for one step — so it is
  STABLE across a duplicate. An adapter that dedupes provider-side by
  `message.send_id` (e.g. as the ESP's own idempotency-key header) turns this
  framework-level at-least-once into an effectively-once send at the provider;
  see `sequence_send_test.exs`'s L8 test, which proves the SAME `send_id` is
  presented on both the original and the duplicate attempt.
  """
  # T75 fix round (bug found while pinning MED-5 with a multi-cycle test): the
  # unique `:states` list EXCLUDES `:completed`/`:cancelled`/`:discarded`
  # (Oban's own default INCLUDES `:completed`, per `Oban.Job`'s
  # `@unique_defaults`). `Samen.Sequences.find_or_create_step_send/2`
  # deliberately REUSES the same `StepSend` row id (hence the same `send_id`
  # arg) across every retry/watchdog cycle for one step — a genuine,
  # legitimate re-enqueue after the row's PRIOR job already reached a
  # terminal state must never be silently deduped against that finished job.
  # `:period` still guards the real race this exists for (a double-enqueue
  # within the SAME transaction/process before either job has run).
  use Oban.Worker,
    queue: :automation_timers,
    max_attempts: 20,
    unique: [period: 60, states: :incomplete]

  require Logger

  alias Samen.Delivery.{Chokepoint, Message}
  alias Samen.Sequences

  @compiled_env Mix.env()

  @doc "Enqueue a delivery attempt for `step_send_id`. Best-effort: never raises."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(step_send_id) do
    %{"send_id" => step_send_id} |> new() |> Oban.insert()
  rescue
    e ->
      Logger.warning("[Sequences.SendWorker] enqueue raised: #{Exception.message(e)}")
      {:error, e}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"send_id" => send_id}}) do
    cfg = config!()

    with {:ok, send_row} <- Sequences.fetch_by_id(cfg.step_send_resource, send_id),
         {:ok, enrollment} <- Sequences.fetch_by_id(cfg.enrollment_resource, send_row.enrollment_id),
         {:ok, sequence} <- Sequences.fetch_by_id(cfg.sequence_resource, enrollment.sequence_id) do
      # :blocked is ALSO deliver-eligible (MED-5 — a step queued while the
      # enrollment was honestly :blocked still gets a genuine delivery
      # attempt the instant an operator wires an adapter). Any OTHER status
      # (:paused/:stopped/:completed — e.g. a manual pause landing between
      # queue and delivery, the race the T75 fix-round verifier's ATK9
      # proved live) is honestly :skipped: the chokepoint is NEVER called.
      if enrollment.status in [:active, :blocked] do
        deliver(send_row, enrollment, sequence, cfg)
      else
        mark(send_row, :skipped, cfg)
        :ok
      end
    else
      {:error, reason} ->
        # T75 fix round MED-2: a fetch-chain failure (including a transient DB
        # blip Samen.Sequences.fetch_by_id/2 rescues) is now RETRIABLE, never
        # `{:discard, _}`. A discard is Oban's PERMANENT "never try again" —
        # combined with the caller's in-flight `next_send_at` (previously
        # `nil`, now a watchdog timestamp — see Samen.Sequences), a discard
        # here used to strand the enrollment forever with no recovery path.
        # Oban's own `max_attempts: 20` backoff now gets a real chance to
        # recover from a transient blip; genuine permanent exhaustion still
        # surfaces (operator-visible in `oban_jobs WHERE state = 'discarded'`)
        # rather than vanishing silently.
        {:error,
         "sequence send: could not load send/enrollment/sequence row (#{inspect(reason)})"}
    end
  end

  defp deliver(send_row, enrollment, sequence, cfg) do
    step = Enum.at(sequence.steps || [], send_row.step_index) || %{}

    message = %Message{
      send_id: send_row.id,
      org_id: send_row.org_id,
      to_subscriber_id: enrollment.person_id,
      template_id: nil
    }

    result =
      Chokepoint.send(message,
        fallback_adapter: resolve_adapter(cfg),
        fallback_config: render_config(step, cfg),
        env: env()
      )

    # T75 fix round (bug found while pinning MED-5 with a multi-cycle test):
    # EVERY branch here returns `:ok` to Oban, NEVER the raw error tuple.
    # `Samen.Sequences`'s own watchdog/backoff mechanism at the ENROLLMENT
    # level is the ONE retry authority for a sequence step (it knows about
    # reply-checks, suppression permanence, and sequence config Oban does
    # not) — a determined outcome (blocked/suppressed/failed) is a
    # SUCCESSFULLY RECORDED result, not a crashed job. Returning `{:error, _}`
    # here previously made OBAN'S OWN backoff/retry state machine ALSO retry
    # the SAME job (`:retryable` state, its own exponential schedule) —
    # racing the enrollment-level watchdog and starving genuine re-enqueues
    # (`find_or_create_step_send/2`'s reuse hits Oban's `unique: [period: 60]`
    # window against the STALE retryable job, blocking a fresh one). Only a
    # genuine fetch-chain failure (`perform/1`'s `else` clause, below) still
    # asks Oban to retry — that IS "the job could not even run".
    case result do
      {:ok, receipt} ->
        mark(send_row, :delivered, cfg,
          sent_at: now(),
          provider_message_id: Map.get(receipt, :provider_message_id)
        )

        Sequences.resolve_outcome(enrollment, sequence, {:ok, receipt})
        :ok

      {:error, :suppressed} = err ->
        mark(send_row, :suppressed, cfg)
        Sequences.resolve_outcome(enrollment, sequence, err)
        :ok

      {:error, :adapter_unconfigured} = err ->
        mark(send_row, :blocked, cfg)
        Sequences.resolve_outcome(enrollment, sequence, err)
        :ok

      {:error, _reason} = err ->
        mark(send_row, :failed, cfg)
        Sequences.resolve_outcome(enrollment, sequence, err)
        :ok
    end
  end

  defp mark(send_row, status, _cfg, extra \\ []) do
    attrs = extra |> Map.new() |> Map.put(:status, status)

    send_row
    |> Ash.Changeset.for_update(:mark, attrs, authorize?: false)
    |> Ash.update()
  rescue
    e ->
      Logger.warning(
        "[Sequences.SendWorker] mark(#{status}) raised send_id=#{Map.get(send_row, :id)}: " <>
          Exception.message(e)
      )

      :ok
  end

  defp render_config(step, cfg) do
    subject = Map.get(step, "subject", "")
    body = Map.get(step, "body", "")
    Map.merge(cfg.adapter_config, %{subject: subject, text_body: body, html_body: body})
  end

  defp resolve_adapter(cfg), do: cfg.adapter

  defp config! do
    raw = Application.get_env(:samen_core, __MODULE__, [])

    %{
      sequence_resource: Keyword.fetch!(raw, :sequence_resource),
      enrollment_resource: Keyword.fetch!(raw, :enrollment_resource),
      step_send_resource: Keyword.fetch!(raw, :step_send_resource),
      adapter: Keyword.get(raw, :adapter),
      adapter_config: Keyword.get(raw, :adapter_config, %{})
    }
  end

  @doc false
  def env, do: Application.get_env(:samen_core, :delivery_env, @compiled_env)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
