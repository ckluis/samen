defmodule Samen.Web.Chat.PubSub do
  @moduledoc """
  The realtime transport for chat (ADR-012 §3) — a `Phoenix.PubSub` topic PER THREAD, with an
  **id-only** broadcast envelope so plaintext NEVER transits PubSub.

  ## The topic

  `"samen:chat:<thread_id>"`. Every session viewing a thread subscribes to its topic; a send
  broadcasts to it; each subscriber's `handle_info` re-reads the message through
  `Samen.Web.Chat.Reads.get_message/3` with ITS OWN scope, so the body resolves per the
  RECEIVING viewer's plane (§3.2). This is why masking survives the realtime path by
  construction (red path 3): the broadcast carries the message ID, never a resolved body, so a
  masked operator session cannot receive plaintext even by listening on the topic.

  ## The pubsub server

  The server name is a HOST fact, read from the mount's `:pubsub` label (default
  `Driftwood.PubSub` — the running server in the reference vertical; any host overrides via the
  label). This mirrors how the framework threads `repo` — a host fact carried on the mount,
  never hardcoded.
  """

  alias Samen.Web.Mount

  @doc "The PubSub topic for a thread id."
  @spec topic(String.t()) :: String.t()
  def topic(thread_id) when is_binary(thread_id), do: "samen:chat:" <> thread_id

  @doc "The pubsub server name for a mount (`:pubsub` label; default `Driftwood.PubSub`)."
  @spec server(Mount.t()) :: atom()
  def server(%Mount{} = mount), do: Mount.label(mount, :pubsub, Driftwood.PubSub)

  @doc """
  Subscribe the calling process to a thread's topic. Called in the room LiveView's `mount/3`
  (only on the connected socket). `{:error, _}` if the server is not running (dead-render /
  test without a PubSub) — the caller tolerates it (the first render still works; realtime
  just won't deliver until a live server is present).
  """
  @spec subscribe(Mount.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(%Mount{} = mount, thread_id) do
    Phoenix.PubSub.subscribe(server(mount), topic(thread_id))
  rescue
    e -> {:error, e}
  end

  @doc """
  Broadcast an **id-only** message envelope on a thread's topic (ADR-012 §3.1). The envelope
  carries the message ID, sender party, participant id, and parsed refs — deliberately NOT the
  resolved/plaintext body. Each subscriber re-reads per its own plane. Returns `:ok` (or
  `{:error, _}` if the server is down — the message is already persisted, so a broadcast
  failure never loses data; the sender's own session appended optimistically).
  """
  @spec broadcast_message(Mount.t(), String.t(), map()) :: :ok | {:error, term()}
  def broadcast_message(%Mount{} = mount, thread_id, %{} = envelope) do
    Phoenix.PubSub.broadcast(server(mount), topic(thread_id), {:chat_message, envelope})
  rescue
    e -> {:error, e}
  end
end
