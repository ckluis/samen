defmodule Samen.Web.Notifications.PubSub do
  @moduledoc """
  The realtime transport for the notifications inbox (WS-A design §2.4; ADR-016 §4) —
  `Phoenix.PubSub` topics with the **id-only** envelope contract, reusing the chat
  pattern (ADR-012 §3) verbatim: plaintext NEVER transits PubSub.

  ## The topics

    * `"samen:notifications:<org_id>:<recipient_id>"` — the per-recipient topic the
      kernel's ADR-016 contract names (`Samen.Notifications.Broadcaster` docs). A
      session viewing one recipient's inbox subscribes here.
    * `"samen:notifications:<org_id>"` — the org-wide topic. The framework inbox is
      the ORG's inbox (every recipient in the org), so it subscribes here; the
      broadcaster publishes the SAME id-only envelope on both.

  Publishing an id-only envelope on the org topic adds no leak surface: the envelope
  carries bounded ids/enums only, and every subscriber RE-READS the record through its
  OWN scope — `Samen.Policy.OrgScope` gates the read and `Samen.Api.PiiResolution`
  masks per plane. Masking survives the realtime path by construction (Invariant N1).

  ## The pubsub server

  A HOST fact, read from the mount's `:pubsub` label (default `Driftwood.PubSub` — the
  running server in the reference vertical), exactly like `Samen.Web.Chat.PubSub`.
  """

  alias Samen.Web.Mount

  @doc "The per-recipient PubSub topic (the ADR-016 broadcaster contract)."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(org_id, recipient_id) when is_binary(org_id) and is_binary(recipient_id),
    do: "samen:notifications:#{org_id}:#{recipient_id}"

  @doc "The org-wide PubSub topic the framework inbox subscribes to."
  @spec org_topic(String.t()) :: String.t()
  def org_topic(org_id) when is_binary(org_id), do: "samen:notifications:#{org_id}"

  @doc "The pubsub server name for a mount (`:pubsub` label; default `Driftwood.PubSub`)."
  @spec server(Mount.t()) :: atom()
  def server(%Mount{} = mount), do: Mount.label(mount, :pubsub, Driftwood.PubSub)

  @doc """
  Subscribe the calling process to the org-wide notifications topic. Called in the
  inbox LiveView's `mount/3` (connected socket only). `{:error, _}` if the server is
  not running (dead render / test without a PubSub) — the caller tolerates it: the
  first render still works; realtime just won't deliver until a server is present.
  """
  @spec subscribe_org(Mount.t(), String.t()) :: :ok | {:error, term()}
  def subscribe_org(%Mount{} = mount, org_id) do
    Phoenix.PubSub.subscribe(server(mount), org_topic(org_id))
  rescue
    e -> {:error, e}
  end

  @doc "Subscribe the calling process to ONE recipient's notifications topic."
  @spec subscribe(Mount.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(%Mount{} = mount, org_id, recipient_id) do
    Phoenix.PubSub.subscribe(server(mount), topic(org_id, recipient_id))
  rescue
    e -> {:error, e}
  end
end
