defmodule Samen.Support.Chat.Transcript do
  @moduledoc """
  A chat-agnostic transcript projection for the C6 offline-escalation capability
  (T60). Given an ordered list of transcript ENTRIES — each an already-plaintext
  chat message the caller resolved on its OWN plane — this renders a single inert
  visible-text body for the escalated ticket, and answers the two questions the
  offline trigger needs: how many CUSTOMER messages exist and when the last one
  landed.

  ## Entry shape

  An entry is a map with (string- or atom-keyed):

    * `:sender_type` — `:customer | :agent | :system` (the party class; only
      `:customer` entries count toward the unserved trigger — we never escalate our
      OWN agent/system messages)
    * `:sender_label` — a SAFE display handle (never a vaulted name); rendered as the
      line prefix
    * `:body` — the message text (plaintext, resolved on the caller's plane)
    * `:at` — a `DateTime` the message was sent (optional; drives `last_customer_at/1`)

  ## Stored-XSS (T111 lineage)

  Every rendered field is pushed through `Samen.Support.Inbound.Sanitize.plain_text/1`
  — the SAME inert-at-rest sanitizer T59 uses — so a `<script>` / `<img onerror=…>` in
  a chat message is neutralized in the transcript body BEFORE it is handed to the
  ticket-creation path (which vaults + re-sanitizes it in turn). Defense in depth: the
  transcript body that lands on the ticket carries no live tag.
  """

  alias Samen.Support.Inbound.Sanitize

  @type entry :: map()

  @doc """
  Render the transcript entries to a single inert multi-line body. Each line is
  `"<safe label>: <sanitized body>"`. Returns `""` for an empty list.
  """
  @spec render([entry()]) :: String.t()
  def render(entries) when is_list(entries) do
    entries
    |> Enum.map(&render_line/1)
    |> Enum.join("\n")
  end

  defp render_line(entry) do
    label = Sanitize.plain_text(to_string(field(entry, :sender_label) || field(entry, :sender_type) || "party"))
    body = Sanitize.plain_text(to_string(field(entry, :body) || ""))
    "#{label}: #{body}"
  end

  @doc """
  Count the CUSTOMER-authored entries. Agent/system messages (our OWN side) do NOT
  count — an agent/system-only thread has nothing to escalate.
  """
  @spec customer_count([entry()]) :: non_neg_integer()
  def customer_count(entries) when is_list(entries) do
    Enum.count(entries, &(entry_type(&1) == :customer))
  end

  @doc """
  The `DateTime` of the last CUSTOMER entry carrying an `:at`, or `nil` when none.
  """
  @spec last_customer_at([entry()]) :: DateTime.t() | nil
  def last_customer_at(entries) when is_list(entries) do
    entries
    |> Enum.filter(&(entry_type(&1) == :customer))
    |> Enum.map(&field(&1, :at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] -> nil
      ats -> Enum.max(ats, DateTime)
    end
  end

  @doc """
  Derive a bounded, sanitized subject line from the first customer entry (or a
  default). Never longer than 120 chars.
  """
  @spec subject([entry()]) :: String.t()
  def subject(entries) when is_list(entries) do
    first_customer =
      entries
      |> Enum.filter(&(entry_type(&1) == :customer))
      |> List.first()

    text =
      case first_customer do
        nil -> nil
        entry -> Sanitize.plain_text(to_string(field(entry, :body) || ""))
      end

    case text do
      nil -> "Chat escalation"
      "" -> "Chat escalation"
      t -> "Chat escalation: " <> String.slice(t, 0, 100)
    end
  end

  @doc """
  The normalized party class of an entry (`:customer | :agent | :system`), or `nil`.
  A hostile/unknown value never raises — it simply isn't `:customer`, so it cannot
  drive an escalation.
  """
  @spec entry_type(entry()) :: :customer | :agent | :system | nil
  def entry_type(entry) do
    case field(entry, :sender_type) do
      t when t in [:customer, :agent, :system] -> t
      "customer" -> :customer
      "agent" -> :agent
      "system" -> :system
      _ -> nil
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil
end
