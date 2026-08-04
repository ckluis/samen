defmodule Samen.Web.Chat.Escalation do
  @moduledoc """
  The crossplane-chat (ADR-012) adopter of the C6 offline-escalation capability (T60).
  The capability itself lives in `samen_core` (`Samen.Support.Chat.Escalation`); this is
  the THIN chat-native wiring the LiveView/host calls — ≈0 authored governance LOC. It
  contributes only the two chat-specific translations:

    1. **Honest agent presence** (`agents_online/1`) — the "is a support agent here?"
       count is derived from the REAL `Phoenix.Presence.list/1` roster on the thread
       topic, counting the OPERATOR-party members present. It is never fabricated: no
       presence entry ⇒ no agent online. (In the crossplane chat the tenant party is the
       help-seeking customer; the operator party is the support agent.)
    2. **Transcript mapping** (`transcript_entry/3`) — a `ChatMessage` (already resolved
       on the reader's plane via `Samen.Web.Chat.Reads.get_message/3`) becomes a core
       `Samen.Support.Chat.Transcript` entry, mapping `sender_party` (`:tenant`/
       `:operator`) to the support party class (`:customer`/`:agent`).

  `build_signal/3` assembles the honest `Presence.evaluate/1` signal; `maybe_escalate/2`
  delegates straight to the framework capability (which vaults the transcript into an
  org-scoped ticket + fires the fail-honest email fallback — all governance lives there).
  """

  alias Samen.Support.Chat.{Config, Escalation, Presence, Transcript}

  @doc """
  Honest count of support AGENTS present on the thread, from a `Phoenix.Presence.list/1`
  result (`%{presence_key => %{metas: [meta]}}`) or a flat list of metas. Counts only
  OPERATOR-party members — the customer's own presence never counts as "an agent is here".
  """
  @spec agents_online(map() | [map()]) :: non_neg_integer()
  def agents_online(presence) when is_map(presence) do
    presence
    |> Enum.flat_map(fn
      {_key, %{metas: metas}} when is_list(metas) -> metas
      _ -> []
    end)
    |> count_operators()
  end

  def agents_online(metas) when is_list(metas), do: count_operators(metas)

  defp count_operators(metas), do: Enum.count(metas, &(meta_party(&1) == :operator))

  defp meta_party(meta) when is_map(meta), do: Map.get(meta, :party) || Map.get(meta, "party")
  defp meta_party(_), do: nil

  @doc """
  Map a plane-resolved `ChatMessage` into a core transcript entry. `resolved_body` is the
  message body ALREADY resolved on the reader's plane (via `Reads.get_message/3`) — this
  module never bypasses `PiiResolution`. `label` is the SAFE participant handle (never a
  vaulted name).
  """
  @spec transcript_entry(map(), term(), String.t() | nil) :: map()
  def transcript_entry(message, resolved_body, label) do
    %{
      sender_type: sender_type(Map.get(message, :sender_party)),
      sender_label: label,
      body: to_string(resolved_body || ""),
      at: Map.get(message, :inserted_at) || Map.get(message, :created_at)
    }
  end

  # Crossplane chat: tenant party = the help-seeking customer; operator party = agent.
  defp sender_type(:operator), do: :agent
  defp sender_type("operator"), do: :agent
  defp sender_type(_), do: :customer

  @doc """
  Assemble the honest `Presence.evaluate/1` signal from mapped transcript entries + the
  live presence roster.
  """
  @spec build_signal([map()], map() | [map()], keyword()) :: map()
  def build_signal(entries, presence, opts \\ []) do
    %{
      agents_online: agents_online(presence),
      customer_messages: Transcript.customer_count(entries),
      last_customer_at: Transcript.last_customer_at(entries),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      sla_seconds: Keyword.get(opts, :sla_seconds, 300),
      leave_message?: Keyword.get(opts, :leave_message?, false)
    }
  end

  @doc "The honest offline/unserved decision for a chat (delegates to `Presence.evaluate/1`)."
  @spec evaluate(map()) :: :serve | {:escalate, Presence.reason()}
  defdelegate evaluate(signal), to: Presence

  @doc """
  Evaluate the honest trigger and, only when unserved, escalate via the framework
  capability (`Samen.Support.Chat.Escalation.escalate/2`). `ctx` must carry `:signal`,
  `:thread_ref`, `:entries`, and `:requester` (see the core capability).
  """
  @spec maybe_escalate(map(), Config.t()) ::
          {:ok, :served} | {:ok, map()} | {:error, term()}
  defdelegate maybe_escalate(ctx, config), to: Escalation
end
