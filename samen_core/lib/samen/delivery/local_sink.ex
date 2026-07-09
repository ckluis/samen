defmodule Samen.Delivery.LocalSink do
  @moduledoc """
  Dev/test delivery adapter — an HONEST "captured, not delivered" (ADR-014 §2).

  `LocalSink` does NOT send a real email. It logs the token-only
  `Samen.Delivery.Message` (opaque IDs only — no revealed recipient email) and
  returns `{:ok, %{sink: true, ...}}`. Because the receipt is explicitly tagged
  `sink: true`, a send it "delivers" is provably NOT a real dispatch — the
  captured flag travels with the send's receipt so a reader can never mistake a
  sink capture for a live delivery.

  ## NOT an Ash resource (orchestrator decision)

  `LocalSink` is a plain log, NOT an Ash resource and NOT a database table. This
  is deliberate: realizing it as a resource would demand a new per-mount abbrev
  (`dsk`) and a suppression-style abbrev tax on every vertical. A process/log sink
  needs no abbrev registry entry (design.md §Data map note). If a host wants a
  durable capture table it can supply its own adapter; the kernel default stays a
  log.

  `configured?/1` is always `true` — the sink is always "ready" because capturing
  is a local no-network operation. It is only *selected* in dev/test (the
  `SendWorker` chooses it as the default adapter when env is `:test`); it must
  never be the default in prod (a prod send that "delivered" to a log is exactly
  the lie ADR-014 forbids, so the SendWorker refuses an unconfigured prod adapter
  rather than falling back to the sink).
  """
  @behaviour Samen.Delivery.Adapter

  require Logger

  alias Samen.Delivery.Message

  @impl Samen.Delivery.Adapter
  def configured?(_config), do: true

  @impl Samen.Delivery.Adapter
  def deliver(%Message{} = message, _config) do
    Logger.info(
      "[Samen.Delivery.LocalSink] captured (NOT delivered) send_id=#{message.send_id} " <>
        "org_id=#{message.org_id} to_subscriber_id=#{message.to_subscriber_id} " <>
        "template_id=#{message.template_id}"
    )

    {:ok,
     %{
       sink: true,
       adapter: __MODULE__,
       send_id: message.send_id,
       captured_at: DateTime.utc_now()
     }}
  end
end
