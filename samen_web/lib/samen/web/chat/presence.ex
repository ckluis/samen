defmodule Samen.Web.Chat.Presence do
  @moduledoc """
  Who's-online + typing for chat (ADR-012 §3.3), via `Phoenix.Presence`. The host adds this to
  its supervision tree (a one-time add, documented on `Samen.Web.Chat.Router.samen_chat_routes`)
  with its own pubsub server.

  ## Non-PII meta BY CONSTRUCTION (red path 4)

  The presence meta is `%{party: :tenant|:operator, handle: <safe label>, typing: bool,
  online_at: ...}` — **no vaulted field**. The `handle` is the always-safe display label (§5.4),
  so the presence roster on the operator side shows a tenant participant's HANDLE, never the
  vaulted name. There is no code path here that carries a real name — the roster is rendered
  through the SAME identity model (§5) as the participant card, and only the handle is tracked.

  ## Configuration

  The host supervises this with `{Samen.Web.Chat.Presence, pubsub_server: Driftwood.PubSub}`
  (or its own server). In test, presence is exercised via the meta-builder `meta/2` (a pure
  function asserting the non-PII shape) plus the `Phoenix.Presence` behaviour at the integration
  layer; the gating realtime assertion is the PubSub `handle_info` re-read, not presence.
  """
  use Phoenix.Presence,
    otp_app: :samen_web,
    pubsub_server: Driftwood.PubSub

  @doc """
  Build the non-PII presence meta for a participant (§3.3). NEVER includes `full_name` — only
  the safe `handle`, the `party`, and volatile `typing`/`online_at`. This is the ONLY shape
  tracked, so the presence roster cannot leak a real name (red path 4).
  """
  @spec meta(map(), keyword()) :: map()
  def meta(participant, opts \\ []) do
    %{
      party: Map.get(participant, :party, :tenant),
      handle: Map.get(participant, :handle),
      participant_id: Map.get(participant, :id),
      typing: Keyword.get(opts, :typing, false),
      online_at: System.system_time(:second)
    }
  end
end
