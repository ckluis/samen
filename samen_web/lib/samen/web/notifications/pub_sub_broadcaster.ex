defmodule Samen.Web.Notifications.PubSubBroadcaster do
  @moduledoc """
  The `Phoenix.PubSub`-backed implementation of the kernel's realtime delivery seam
  (`Samen.Notifications.Broadcaster`, ADR-016 §4 / Invariant N1) — the web half the
  kernel engine hands its **id-only** envelope to. A host wires it via config:

      config :samen_core, Samen.Notifications.Engine,
        broadcaster: Samen.Web.Notifications.PubSubBroadcaster

      config :samen_web, Samen.Web.Notifications.PubSubBroadcaster,
        pubsub: Driftwood.PubSub

  ## Invariant N1, ENFORCED at this seam (not just documented)

  The broadcaster contract says it "MUST NOT enrich the envelope with the rendered
  body or any resolved PII". This implementation goes one step further and makes a
  plaintext transit STRUCTURALLY impossible through this module: the published
  envelope is `Map.take/2`-narrowed to exactly the five bounded routing keys
  (`:id`, `:org_id`, `:recipient_id`, `:event_type`, `:channel`). Even a buggy or
  hostile caller handing an envelope that carries a `:rendered_body` cannot push it
  onto a topic — subscribers receive the id-only envelope and must re-read the
  record through their OWN scope, where `PiiResolution` masks per plane (the
  RP-G2-10 red path asserts this stripping).

  Publishes the same envelope on BOTH the per-recipient topic
  (`samen:notifications:<org_id>:<recipient_id>`, the ADR-016 contract) and the
  org-wide topic (`samen:notifications:<org_id>`, the framework inbox's
  subscription) — see `Samen.Web.Notifications.PubSub`.

  A broadcast failure never loses data (the record is already persisted); the
  engine logs and continues — the inbox re-reads on next mount.
  """

  @behaviour Samen.Notifications.Broadcaster

  alias Samen.Web.Notifications.PubSub, as: NotificationsPubSub

  # The BOUNDED envelope keys (Samen.Notifications.Engine.envelope/5). Everything
  # else — including any body-shaped key — is stripped before publish.
  @envelope_keys [:id, :org_id, :recipient_id, :event_type, :channel]

  @doc "The bounded key set this broadcaster lets transit PubSub (introspection/tests)."
  def envelope_keys, do: @envelope_keys

  @impl true
  def broadcast(%{id: _, org_id: org_id, recipient_id: recipient_id} = envelope)
      when is_binary(org_id) and is_binary(recipient_id) do
    server = pubsub_server()
    message = {:notification_created, Map.take(envelope, @envelope_keys)}

    with :ok <-
           Phoenix.PubSub.broadcast(
             server,
             NotificationsPubSub.topic(org_id, recipient_id),
             message
           ) do
      Phoenix.PubSub.broadcast(server, NotificationsPubSub.org_topic(org_id), message)
    end
  rescue
    e -> {:error, e}
  end

  def broadcast(_envelope), do: {:error, :malformed_envelope}

  # The pubsub server is a HOST fact. The broadcaster has no mount (it is called from
  # the kernel engine), so the host wires it via app config; default = the reference
  # vertical's server, mirroring Samen.Web.Chat.PubSub.
  defp pubsub_server do
    :samen_web
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:pubsub, Driftwood.PubSub)
  end
end
