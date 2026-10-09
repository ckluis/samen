defmodule Samen.Pii.Plaintext do
  @moduledoc """
  A vault-routed value IN FLIGHT: the plaintext a caller set on a `pii_attribute`, between
  `Samen.Type.VaultField.cast_input/2` and `Samen.Vault.Change` replacing it with a token
  (ADR-052 §2.1 item 3).

  Ash honours `sensitive?: true` when it inspects a RECORD (the field is hidden) and a
  changeset ARGUMENT (`**redacted**`), but NOT a changeset ATTRIBUTE: `inspect(changeset)`
  printed `attributes: %{emails: [... "alice@example.com" ...]}` — and so did every log line,
  crash report or `FunctionClauseError` "arguments given" blame that inspected a changeset
  before the vault write. Wrapping the cast value closes that at the type: this struct's
  `Inspect` prints `#Samen.Pii.Plaintext<**redacted**>`, whatever the caller does.

  Code that legitimately needs the pending plaintext opens it with `unwrap/1`: the encrypting
  write path (`Samen.Vault.Change`), the AI fold-provenance indexer
  (`Samen.AI.Agent.FoldSource`, which reads the transcript before it is vaulted), and a
  LiveView editing its own draft (`AshPhoenix.Form.value(form, :vaulted_field)` returns the
  wrapper — e.g. `Samen.Web.Support.TicketLive`'s composer).
  `Samen.Pii.WriteGuard` only needs to know a non-token value is SET, which the wrapper is. `Samen.Type.VaultField.dump_to_native/2` refuses this
  struct exactly as it refused raw plaintext — an unrouted value still fails closed.

  Not a secrecy boundary against code that reaches into `.value` (or inspects with
  `structs: false`): it is a guard against ACCIDENTAL exposure through inspection.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  @doc "Wrap a plaintext value (idempotent)."
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = p), do: p
  def wrap(value), do: %__MODULE__{value: value}

  @doc "The plaintext inside a wrapper; any other value is returned as-is."
  @spec unwrap(term()) :: term()
  def unwrap(%__MODULE__{value: value}), do: value
  def unwrap(other), do: other

  defimpl Inspect do
    def inspect(_plaintext, _opts), do: "#Samen.Pii.Plaintext<**redacted**>"
  end

  # A form re-rendered after a failed validate shows the caller's OWN pending input back to
  # them — exactly what it rendered before the value was wrapped (HTML-escaped by the inner
  # value's own impl). This is the form round-trip, not a read: a stored vault value is a
  # `%Samen.Masked{}` and renders `••••` per plane as always.
  if Code.ensure_loaded?(Phoenix.HTML.Safe) do
    defimpl Phoenix.HTML.Safe do
      def to_iodata(%Samen.Pii.Plaintext{value: value}), do: Phoenix.HTML.Safe.to_iodata(value)
    end
  end
end
