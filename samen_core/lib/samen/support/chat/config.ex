defmodule Samen.Support.Chat.Config do
  @moduledoc """
  Host-supplied wiring for the C6 chat-escalation capability (T60). The capability
  lives in `samen_core`; a vertical adopts it at ≈0 authored LOC by handing this
  struct its OWN Support-scope resource modules (+ optionally a CRM `Person`-shaped
  contact resource) and its delivery parameters. Every field is host-authoritative —
  nothing here is derived from untrusted chat content.

  ## Fields

  | Field                         | Purpose                                                     |
  |-------------------------------|-------------------------------------------------------------|
  | `:org_id` (req)               | tenant boundary (trusted; NEVER from chat content)          |
  | `:repo` (req)                 | host repo (vault + reads)                                   |
  | `:ticket_resource` (req)      | host `Ticket` module                                        |
  | `:conversation_resource` (req)| host `Conversation` module                                  |
  | `:message_resource` (req)     | host `Message` module (🔒 body)                             |
  | `:contact_resource`           | host CRM `Person`-shaped module (🔒); nil skips             |
  | `:our_domains` / `:our_addresses` | our OWN sending identity (loop-guard, passed to T59)    |
  | `:inbound_localpart`          | support inbox local part (passed to T59)                   |
  | `:sla_seconds`                | unserved threshold + escalation deadline (default #{300})  |
  | `:escalation_module`          | T41 automation Escalation resource (nil skips the primitive)|
  | `:escalation_repo`            | repo for the automation module (defaults from the resource) |
  | `:escalation_chain`           | T41 chain steps; nil = the default single-step org chain    |
  | `:escalation_template_id`     | opaque delivery template id for the fallback email          |
  | `:delivery_env`               | delivery env for the chokepoint (default `:prod`)          |
  | `:fallback_adapter` / `:fallback_config` | legacy per-worker provider fallback for the send |
  """

  @enforce_keys [:org_id, :repo, :ticket_resource, :conversation_resource, :message_resource]
  defstruct [
    :org_id,
    :repo,
    :ticket_resource,
    :conversation_resource,
    :message_resource,
    :contact_resource,
    :inbound_localpart,
    :escalation_module,
    :escalation_repo,
    :escalation_chain,
    :escalation_template_id,
    :fallback_adapter,
    :fallback_config,
    our_domains: [],
    our_addresses: [],
    sla_seconds: 300,
    delivery_env: :prod
  ]

  @type t :: %__MODULE__{}

  @doc "Build a validated config from a keyword list / map."
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    struct!(__MODULE__, Map.new(opts))
  end
end
