defmodule Samen.Notifications.LogBroadcaster do
  @moduledoc """
  The kernel default `Samen.Notifications.Broadcaster` — an honest structured log
  ("captured, not transported"). It exercises the realtime seam without pulling a
  PubSub dependency into the web-dep-free kernel (AC-X-1).

  It logs ONLY the id-only envelope fields (id + bounded routing keys) — the same
  data the PubSub-backed `samen_web` broadcaster would publish. There is no rendered
  body here (Invariant N1): the log is as safe as the envelope by construction.
  """
  @behaviour Samen.Notifications.Broadcaster

  require Logger

  @impl true
  def broadcast(envelope) when is_map(envelope) do
    Logger.debug(fn ->
      "[Notifications.LogBroadcaster] id=#{inspect(envelope[:id])} " <>
        "org=#{inspect(envelope[:org_id])} recipient=#{inspect(envelope[:recipient_id])} " <>
        "event=#{inspect(envelope[:event_type])} channel=#{inspect(envelope[:channel])} " <>
        "(id-only — no body transported)"
    end)

    :ok
  end
end
