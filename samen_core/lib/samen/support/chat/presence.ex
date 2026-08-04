defmodule Samen.Support.Chat.Presence do
  @moduledoc """
  The HONEST offline/unserved decision for the C6 chat-escalation capability (T60).

  This is a PURE function over a `signal` the caller assembles. It invents NO
  presence of its own — the crux of "be honest about how offline is determined": the
  `:agents_online` count MUST come from a real presence source (in the crossplane
  chat, `Phoenix.Presence.list/1` on the thread topic, counting the AGENT/operator-
  party members — never the customer, never a fabricated "someone is probably here").
  When the caller genuinely cannot determine presence it passes the honest value; it
  does not get to pretend an agent is online.

  ## The rule (`evaluate/1`)

  Given `signal`:

    * `:agents_online`     — non-neg count of agents/operators PRESENT (from real presence)
    * `:customer_messages` — count of CUSTOMER messages in the thread
    * `:last_customer_at`  — `DateTime` of the last customer message (or `nil`)
    * `:now`               — current `DateTime` (defaults to `DateTime.utc_now/0`)
    * `:sla_seconds`       — unanswered-response threshold (default #{300})
    * `:leave_message?`    — the visitor explicitly chose "leave a message" (bool)

  Returns:

    * `:serve` — the chat can be (or is being) served; do NOT escalate
    * `{:escalate, :leave_message}` — the visitor opted out of waiting
    * `{:escalate, :no_agent_online}` — zero agents present for the thread
    * `{:escalate, :sla_elapsed}` — an agent is nominally present but no answer within SLA

  A thread with **zero customer messages never escalates** (`:serve`) — we do not
  escalate our OWN agent/system chatter, and an empty/greeting-only thread has nothing
  to hand off. This is the first loop-guard: the trigger keys on unserved CUSTOMER
  demand, not on any message event.
  """

  @default_sla_seconds 300

  @type reason :: :leave_message | :no_agent_online | :sla_elapsed
  @type signal :: %{optional(atom()) => term()}

  @doc "Pure honest offline/unserved decision. See the module doc."
  @spec evaluate(signal()) :: :serve | {:escalate, reason()}
  def evaluate(signal) when is_map(signal) do
    cond do
      customer_messages(signal) <= 0 ->
        :serve

      truthy(signal, :leave_message?) ->
        {:escalate, :leave_message}

      agents_online(signal) <= 0 ->
        {:escalate, :no_agent_online}

      sla_elapsed?(signal) ->
        {:escalate, :sla_elapsed}

      true ->
        :serve
    end
  end

  defp customer_messages(signal), do: nonneg(get(signal, :customer_messages, 0))

  defp agents_online(signal), do: nonneg(get(signal, :agents_online, 0))

  defp sla_elapsed?(signal) do
    case get(signal, :last_customer_at) do
      %DateTime{} = last ->
        now = now(signal)
        sla = nonneg(get(signal, :sla_seconds, @default_sla_seconds))
        DateTime.diff(now, last, :second) >= sla

      _ ->
        false
    end
  end

  defp now(signal) do
    case get(signal, :now) do
      %DateTime{} = dt -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp truthy(signal, key), do: get(signal, key) == true

  defp get(signal, key, default \\ nil) do
    case Map.get(signal, key, Map.get(signal, to_string(key), default)) do
      nil -> default
      v -> v
    end
  end

  defp nonneg(n) when is_integer(n) and n >= 0, do: n
  defp nonneg(_), do: 0
end
