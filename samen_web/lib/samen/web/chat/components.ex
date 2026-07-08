defmodule Samen.Web.Chat.Components do
  @moduledoc """
  Chat UI components (ADR-012 §6.1) — `<.chat_message>`, `<.presence_roster>`,
  `<.identity_chip>`. UI-kit-styled (ADR-008) and `%Masked{}`-safe: every PII value rendered
  here is the resolver's ALREADY-RESOLVED field, so a `%Masked{}` renders `••••` verbatim
  through `Phoenix.HTML.Safe`. These components have NO unmasking branch.

  The inline object-unfurl card is `Samen.UI.object_card/1` (the crown-jewel renderer) — a
  message's resolved cards are rendered inline via that component, per viewer.
  """
  use Phoenix.Component

  import Samen.UI, only: [pill: 1, object_card: 1]

  @doc """
  A single chat message row: the sender handle + party, the (plane-resolved) body, and any
  inline object-unfurl cards. `cards` is the list of `{ref, card_or_error}` from
  `Samen.Web.Chat.resolve_cards/3` — each rendered per-viewer-masked via `<.object_card>`.
  """
  attr :message, :map, required: true
  attr :handle, :string, default: nil
  attr :cards, :list, default: []
  attr :mine, :boolean, default: false

  def chat_message(assigns) do
    ~H"""
    <div class={["chat-msg", @mine && "chat-msg-mine"]} id={"chat-msg-#{@message.id}"} data-sender-party={@message.sender_party}>
      <div class="chat-msg-head">
        <span class="chat-msg-handle">{@handle || "—"}</span>
        <.pill variant={party_variant(@message.sender_party)}>{@message.sender_party}</.pill>
      </div>
      <div class="chat-msg-body">{@message.body}</div>
      <div :if={@cards != []} class="chat-msg-unfurls">
        <.object_card :for={{_ref, result} <- @cards} card={unwrap_card(result)} />
      </div>
    </div>
    """
  end

  @doc """
  The presence roster — who's-online, rendered through the identity model. Each entry shows the
  participant's HANDLE (always safe) + an identity chip (the plane-resolved name, or `••••` +
  a reveal affordance on the operator side under the masked floor). `participants` are ALREADY
  identity-resolved (via `Samen.Web.Chat.Identity.resolve_participants/4`).
  """
  attr :participants, :list, default: []
  attr :online_ids, :list, default: []

  def presence_roster(assigns) do
    ~H"""
    <div class="chat-roster" id="chat-roster">
      <div :for={p <- @participants} class="chat-roster-row" id={"roster-#{p.id}"} data-party={p.party}>
        <span class={["chat-roster-dot", (p.id in @online_ids) && "online"]}></span>
        <span class="chat-roster-handle">{p.handle || "—"}</span>
        <.identity_chip participant={p} />
      </div>
    </div>
    """
  end

  @doc """
  The identity chip — renders a participant's identity as resolved by the identity model. A
  disclosed participant shows the clear name; a masked one shows `••••` (the resolver's
  `%Masked{}`). NO unmasking here — the value is whatever `resolve_participant/4` returned.
  """
  attr :participant, :map, required: true

  def identity_chip(assigns) do
    ~H"""
    <span class="chat-identity-chip" data-identity-masked={masked?(@participant.full_name)}>
      {render_identity(@participant.full_name, @participant.handle)}
    </span>
    """
  end

  # -- helpers (MASKING INVARIANT — render resolved values only) ----------------

  # `Samen.Web.Chat.resolve_cards/3` returns `{ref, {:ok, card} | {:error, reason}}`. The
  # `<.object_card>` component renders a `%Card{}` or an `{:error, reason}` chip — so unwrap the
  # ok tuple, and pass an error through verbatim (→ the inert "not available" chip; never a leak).
  defp unwrap_card({:ok, card}), do: card
  defp unwrap_card({:error, _} = err), do: err
  defp unwrap_card(other), do: other

  defp party_variant(:operator), do: "info"
  defp party_variant(_), do: "ok"

  defp masked?(%Samen.Masked{}), do: "true"
  defp masked?(_), do: "false"

  # A %Masked{} renders •••• through Phoenix.HTML.Safe (returned as-is). A clear FullName /
  # binary is reshaped to a display string. nil falls back to the handle (never a leak).
  defp render_identity(%Samen.Masked{} = masked, _handle), do: masked

  defp render_identity(%Samen.Type.FullName{first: first, last: last}, handle) do
    case String.trim("#{first} #{last}") do
      "" -> handle || "—"
      name -> name
    end
  end

  defp render_identity(name, _handle) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_identity(nil, handle), do: handle || "—"
  defp render_identity(other, _handle), do: other
end
