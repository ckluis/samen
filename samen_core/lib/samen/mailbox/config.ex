defmodule Samen.Mailbox.Config do
  @moduledoc """
  The host-supplied wiring for the **CRM two-way email sync** capability (spec §I1,
  T74).

  The capability itself lives entirely in `samen_core`
  (`Samen.Mailbox.{Provider,Message,Account,FakeProvider,Match,Sync}` + the
  `Samen.Scopes.Mailbox` blueprint); a vertical adopts it at ≈0 authored LOC by
  handing this struct its OWN mounted resource modules. Nothing here is derived
  from an untrusted message — every field is host-authoritative, and `:org_id` is
  the tenant boundary in exactly the sense `Samen.Support.Inbound.Config` means it:
  it comes from the connected mailbox's OWN record, never from a `From` header.

  ## Fields

  | Field                        | Purpose                                                     |
  |------------------------------|-------------------------------------------------------------|
  | `:org_id` (req)              | tenant boundary (from the Connection row, not headers)      |
  | `:repo` (req)                | host repo (vault reads + writes)                            |
  | `:provider` (req)            | a `Samen.Mailbox.Provider` implementation                   |
  | `:provider_config`           | opaque adapter config (creds/endpoints); `%{}` ⇒ unconfigured |
  | `:connection_resource` (req) | host `Mailbox.Connection` module (🔒 address)                |
  | `:message_resource` (req)    | host `Mailbox.MailMessage` module (🔒 subject/body/address)  |
  | `:person_resource`           | host CRM `Person` module (🔒 emails) — nil disables matching |
  | `:company_resource`          | host CRM `Company` module — nil disables company anchoring   |
  | `:max_messages_per_sync`     | runaway bound per sync run (default 200)                     |
  | `:max_match_candidates`      | bound on the CRM candidate read per match (default 500)      |
  | `:max_body_bytes`            | oversized-body cap (default 256 KiB)                         |
  | `:max_subject_bytes`         | oversized-subject cap (default 4 KiB)                        |

  ## Honest absence

  A config whose `:provider` is `nil`, or whose provider reports
  `configured?/1 == false` for `:provider_config`, is UNCONFIGURED. `Samen.Mailbox`
  then returns `{:error, :not_configured}` from every operation — it never returns
  an empty-but-successful sync, and the CRM mailbox settings surface renders the
  honest "not connected" state rather than a fabricated empty inbox.
  """

  @enforce_keys [:org_id, :repo, :provider, :connection_resource, :message_resource]
  defstruct [
    :org_id,
    :repo,
    :provider,
    :connection_resource,
    :message_resource,
    :person_resource,
    :company_resource,
    provider_config: %{},
    max_messages_per_sync: 200,
    max_match_candidates: 500,
    max_body_bytes: 262_144,
    max_subject_bytes: 4_096
  ]

  @type t :: %__MODULE__{}

  @doc "Build a config from a keyword list / map."
  @spec new(keyword() | map()) :: t()
  def new(opts), do: struct!(__MODULE__, Map.new(opts))

  @doc """
  Is this config backed by a genuinely configured provider? The single predicate
  every honest-empty-state decision reads. A `nil` provider, a module that is not
  loaded, or a provider whose own `configured?/1` says `false` are all `false` —
  there is no third answer and no default-to-true.
  """
  @spec configured?(t() | nil) :: boolean()
  def configured?(%__MODULE__{provider: nil}), do: false

  def configured?(%__MODULE__{provider: provider, provider_config: provider_config}) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :configured?, 1) and
      provider.configured?(provider_config || %{}) == true
  end

  def configured?(_), do: false
end
