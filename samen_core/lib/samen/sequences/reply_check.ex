defmodule Samen.Sequences.ReplyCheck do
  @moduledoc """
  Host-injectable "has this contact replied since T?" seam (spec §I2 reply-
  detection pause) — mirrors `Samen.Delivery.Chokepoint`'s own
  `suppression_module` seam exactly:

      config :samen_core, Samen.Sequences.ReplyCheck,
        module: Samen.Sequences.MailboxReplyCheck

  Unwired (`module: nil`, the default) degrades to `{:ok, false}` — the honest
  "no reply source configured, so replies are never auto-detected" absence
  (mirrors `Samen.Delivery.Chokepoint.suppressed?/2`'s unwired-degrades-open
  default). A configured module that RAISES fails CLOSED **on the send side**:
  `{:error, reason}` propagates to `Samen.Sequences.handle_due/3`, which does
  NOT send this cycle (retries after a short backoff) — "I could not check" is
  never silently treated as "no reply" (the same fail-closed posture
  `Samen.Mailbox.Sync`'s dedupe check and the Chokepoint's suppression check
  both use for "a broken check must never silently let the risky thing
  through").

  `Samen.Sequences.MailboxReplyCheck` is the real, production implementation —
  it reads the ALREADY-SHIPPED T74 Mailbox seam. This behaviour exists so a
  host without Mailbox mounted (or a test proving the pure scheduling
  mechanics) can wire a smaller double instead, without inventing a SECOND
  reply-check contract.
  """

  @doc "The injectable contract: has `person_id` replied since `since`?"
  @callback replied_since?(org_id :: String.t(), person_id :: String.t(), since :: DateTime.t()) ::
              boolean() | {:error, term()}

  @doc "Answer via the configured module (see moduledoc). Never raises."
  @spec replied_since?(String.t(), String.t(), DateTime.t()) :: {:ok, boolean()} | {:error, term()}
  def replied_since?(org_id, person_id, %DateTime{} = since) do
    case module() do
      nil ->
        {:ok, false}

      mod ->
        try do
          case mod.replied_since?(org_id, person_id, since) do
            {:error, _} = err -> err
            bool when is_boolean(bool) -> {:ok, bool}
            other -> {:error, {:invalid_reply_check_result, other}}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  defp module, do: Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:module)
end
