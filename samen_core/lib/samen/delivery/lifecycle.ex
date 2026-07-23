defmodule Samen.Delivery.Lifecycle do
  @moduledoc """
  The framework seam for **transactional lifecycle emails** (ADR-014, F7).

  A host or blueprint calls `deliver/2` to enqueue a lifecycle email for a
  bounded event (welcome/onboarding/trial-ending/payment-failed/
  subscription-cancelled) addressed to an existing subscriber/customer ref. The
  actual dispatch is `Samen.Delivery.Lifecycle.EmailWorker`, which routes through
  the fail-honest `Samen.Delivery.Provider` boundary (ADR-038 §4.2 rename of the
  ADR-014 `Samen.Delivery.Adapter` contract) — a host may BYO its own adapter
  (`docs/guides/byo-esp.md`) or select one of the first-party-but-separate ESP
  adapter packages (ADR-038 §8).

  ## Best-effort by contract (rides alongside a primary write)

  `deliver/2` mirrors `Samen.Notifications.StatusChange`: it is a side-effect that
  rides ALONGSIDE a triggering write (a subscription transitioning to
  `:cancelled`, a payment failing) and must NEVER abort or roll back that write.
  It therefore never raises — an enqueue failure is logged and returned, but a
  caller can ignore the return safely:

      # in a Subscription :cancelled after_action, alongside the existing
      # Samen.Notifications.StatusChange:
      Samen.Delivery.Lifecycle.deliver(:subscription_cancelled,
        org_id: org_id, subscriber_id: customer_id)

  ## Token-only enqueue (F2.1)

  The job args carry ONLY opaque IDs + the bounded event enum. There is NO
  persisted lifecycle-send resource (kept stateless to avoid an abbrev/migration
  tax — design note): a `send_id` correlation UUID is minted here purely as the
  `Samen.Delivery.Message` identity and Oban idempotency key. The recipient email
  is NEVER in the args — it is revealed from the vault at `deliver/2` time by the
  host's adapter under a grant.

  ## Returns

    * `{:ok, %Oban.Job{}}`   — enqueued
    * `{:ok, :skipped}`      — the event is not a recognised lifecycle event, or a
      required ref (`subscriber_id`) is absent; NOTHING was enqueued (fail-closed,
      never a fake enqueue)
    * `{:error, reason}`     — the enqueue itself failed (logged; the caller's
      primary write is unaffected)
  """

  require Logger

  alias Samen.Delivery.Lifecycle.EmailWorker

  @doc """
  Enqueue a lifecycle email for `event` to a subscriber/customer ref. Best-effort:
  never raises, never aborts a caller's primary write.

  ## Options

    * `:org_id`        — owning org UUID (required for scoping; absent → `:skipped`)
    * `:subscriber_id` — recipient ref UUID (required; absent → `:skipped`). Also
      accepted as `:customer_id` / `:to_subscriber_id`.
    * `:template_id`   — template UUID (optional)
    * `:send_id`       — override the minted correlation id (optional; defaults to a
      fresh UUID). Passing a stable id makes the enqueue idempotent per the
      worker's `unique: [period: 60]` window.
  """
  @spec deliver(atom() | String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:ok, :skipped} | {:error, term()}
  def deliver(event, opts \\ []) do
    subscriber_id =
      Keyword.get(opts, :subscriber_id) || Keyword.get(opts, :customer_id) ||
        Keyword.get(opts, :to_subscriber_id)

    org_id = Keyword.get(opts, :org_id)

    cond do
      not EmailWorker.valid_event?(event) ->
        Logger.debug(
          "[Lifecycle] skipped: #{inspect(event)} is not a recognised lifecycle event"
        )

        {:ok, :skipped}

      is_nil(subscriber_id) or is_nil(org_id) ->
        Logger.debug("[Lifecycle] skipped: missing org_id/subscriber_id ref")
        {:ok, :skipped}

      true ->
        args =
          %{
            "send_id" => Keyword.get(opts, :send_id) || Ecto.UUID.generate(),
            "org_id" => to_string(org_id),
            "subscriber_id" => to_string(subscriber_id),
            "template_id" => opt_string(Keyword.get(opts, :template_id)),
            "event" => to_string(event)
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        enqueue(args)
    end
  end

  @doc """
  Insert the lifecycle-email job from already-built token-only args. Best-effort:
  wraps `Oban.insert/1` so an enqueue failure (Oban not started, DB down) is
  logged and returned as `{:error, _}` rather than raised into the caller's write.

  Prefer `deliver/2` — it builds and validates the args. This lower-level seam is
  for hosts that enqueue inside their own `Ecto.Multi` via `Oban.insert/2`.
  """
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(args) when is_map(args) do
    args
    |> EmailWorker.new()
    |> Oban.insert()
  rescue
    e ->
      Logger.warning(
        "[Lifecycle] enqueue raised (primary write unaffected): #{Exception.message(e)}"
      )

      {:error, e}
  end

  defp opt_string(nil), do: nil
  defp opt_string(v), do: to_string(v)
end
