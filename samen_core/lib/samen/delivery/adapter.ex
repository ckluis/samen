defmodule Samen.Delivery.Adapter do
  @moduledoc """
  Pluggable outbound-email delivery contract (ADR-014 §2).

  A host application selects an adapter per environment. The kernel ships:

    * `Samen.Delivery.LocalSink` — dev/test. Logs the rendered message and
      returns `{:ok, %{sink: true}}`: an HONEST "captured, not delivered".
    * `Samen.Delivery.Smtp` / `Samen.Delivery.Api` — **skeletons**. `configured?/1`
      returns `false` when creds are absent, and `deliver/2` returns
      `{:error, :not_configured}` rather than faking success. Real provider
      dispatch is an operator TODO.

  ## The fail-honest contract (Invariant D1)

  The load-bearing rule the `Samen.Scopes.Marketing.SendWorker` enforces on top of
  this behaviour: a send reaches `:delivered` **if and only if** a *configured*
  adapter returned `{:ok, receipt}`. `configured?/1` is the gate — an adapter that
  is not configured must NOT be asked to `deliver/2`, and `deliver/2` itself must
  never return `{:ok, _}` for a dispatch it did not actually perform (or, for
  `LocalSink`, actually capture).

  ## Web-dep-free

  This contract lives in `samen_core` and imposes no web dependency. Adapters that
  need HTTP/SMTP pull their own client; the behaviour references none.
  """

  @doc """
  Returns `true` when the adapter has everything it needs to actually dispatch
  (creds, endpoint, etc.), `false` otherwise. An adapter that answers `false`
  here MUST NOT be routed to `deliver/2` — the caller treats an unconfigured
  adapter as fail-honest `:blocked` in non-test environments.
  """
  @callback configured?(config :: map()) :: boolean()

  @doc """
  Attempt real delivery of a token-only `Samen.Delivery.Message`. Returns
  `{:ok, receipt}` ONLY when the message was actually dispatched (or, for
  `LocalSink`, actually captured); returns `{:error, reason}` otherwise. It must
  NEVER return `{:ok, _}` for a no-op — that is the tautological lie this contract
  exists to abolish.
  """
  @callback deliver(message :: Samen.Delivery.Message.t(), config :: map()) ::
              {:ok, receipt :: map()} | {:error, reason :: term()}
end
