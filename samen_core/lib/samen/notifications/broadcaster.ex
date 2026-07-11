defmodule Samen.Notifications.Broadcaster do
  @moduledoc """
  The **realtime delivery seam** the `samen_web` inbox subscribes to (ADR-016 §4,
  Invariant N1). This behaviour is how the web-dep-free kernel hands an **id-only**
  envelope to a transport (`Phoenix.PubSub`) that lives in `samen_web` — without
  the kernel ever depending on `phoenix`/`phoenix_pubsub` (AC-X-1).

  ## The contract

      @callback broadcast(envelope :: map()) :: :ok | {:error, term()}

  The `envelope` the engine passes is the id-only map (see
  `Samen.Notifications.Engine.envelope/5`):

      %{id: notification_id, org_id: org_id, recipient_id: recipient_id,
        event_type: event_type, channel: channel}

  A broadcaster MUST treat this envelope as opaque routing data: it may derive a
  topic from `org_id` + `recipient_id` (the ADR-012 convention:
  `"samen:notifications:<org_id>:<recipient_id>"`) and publish the envelope, but it
  MUST NOT enrich the envelope with the rendered body or any resolved PII. The
  rendered body is vault-routed and NEVER transits this seam — a subscriber re-reads
  the `Notification` record through its OWN scope, where masking applies per plane.

  ## Kernel default

  `Samen.Notifications.LogBroadcaster` is the shipped default: an honest structured
  log ("captured, not transported"). It proves the seam is exercised without pulling
  a PubSub dependency into the kernel. `samen_web` wires a `Phoenix.PubSub`-backed
  broadcaster in a later A4 unit.
  """

  @doc """
  Publish an id-only notification envelope on the recipient's topic. Returns `:ok`
  (or `{:error, _}` if the transport is unavailable — the caller tolerates it; the
  record is already persisted).
  """
  @callback broadcast(envelope :: map()) :: :ok | {:error, term()}
end
