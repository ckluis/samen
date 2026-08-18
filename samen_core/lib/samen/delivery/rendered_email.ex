defmodule Samen.Delivery.RenderedEmail do
  @moduledoc """
  The recipient-facing rendered email (C3, T29) — the transient product of
  `Samen.Delivery.Rendering.render/5` and the ONLY place the recipient's resolved
  address + a rendered subject/body ever exist together.

  A `RenderedEmail` is **never persisted**. It is built on the send path (through
  the T28 `Samen.Delivery.Chokepoint`), handed to the adapter as the minimal
  provider payload (`provider_payload/1`), and discarded. What survives at rest is
  only its `at_rest_record/1` projection — provider id + template ref + opaque
  refs, NEVER the rendered body (INV-1; ADR-038 §5.4 / spec §C3).

  ## Two projections, two audiences

    * `provider_payload/1` — what the ESP legitimately needs to send the mail:
      the resolved recipient address, subject, and the minimal text/html body. It
      carries ONLY the `@provider_payload_fields` whitelist and is FAIL-CLOSED:
      it refuses (raises) if any value is still a `%Samen.Masked{}` or contains a
      `vt_` vault token — a masked/unresolved value or a vault reference reaching
      the ESP is a real breach (it would leak the vault scheme AND hand the vendor
      a reference it cannot use).
    * `at_rest_record/1` — what a delivery record persists: `@at_rest_fields`
      only (send id, template ref, subscriber ref, provider message id). There is
      structurally NO body/subject/address key, so no plaintext body can land at
      rest by construction.

  ## Fields

    * `:send_id`             — opaque correlation UUID (the `Message` identity)
    * `:template_ref`        — opaque template reference (the render input, not PII)
    * `:to_subscriber_id`    — opaque recipient ref (the vault subject)
    * `:to`                  — the RESOLVED recipient address on the render plane:
                               plaintext on the send/recipient plane, `%Masked{}`
                               (`••••`) on an operator preview
    * `:subject`             — the rendered subject line
    * `:text_body`           — the rendered text body (resolved fields interpolated)
    * `:html_body`           — the rendered html body
    * `:provider_message_id` — the ESP's message id, filled from the deliver receipt
                               AFTER dispatch (nil at render time); the token-blind
                               join key (ADR-038 §4.1/§4.4)
    * `:vault_token_ref`     — the recipient's OWN vault token (internal correlation
                               only). It is deliberately NOT in either the provider
                               payload or the at-rest record — a leak of it into the
                               provider payload is exactly what the payload-minimality
                               sabotage models.
  """

  alias Samen.Masked

  # The ADR-whitelisted provider payload — the ONLY fields an ESP request carries
  # (ADR-038 §4; spec §C3: "the provider payload carries only what the ESP needs").
  @provider_payload_fields [:to, :subject, :text_body, :html_body]

  # The at-rest projection — provider id + template ref + opaque refs, NO body.
  @at_rest_fields [:send_id, :template_ref, :to_subscriber_id, :provider_message_id]

  @enforce_keys [:send_id, :to_subscriber_id]
  defstruct [
    :send_id,
    :template_ref,
    :to_subscriber_id,
    :to,
    :subject,
    :text_body,
    :html_body,
    :provider_message_id,
    :vault_token_ref
  ]

  @type t :: %__MODULE__{
          send_id: String.t(),
          template_ref: String.t() | nil,
          to_subscriber_id: String.t(),
          to: term(),
          subject: String.t() | nil,
          text_body: String.t() | nil,
          html_body: String.t() | nil,
          provider_message_id: String.t() | nil,
          vault_token_ref: String.t() | nil
        }

  @doc "The ADR-whitelisted provider-payload field set (the ONLY keys an ESP request may carry)."
  @spec provider_payload_fields() :: [atom()]
  def provider_payload_fields, do: @provider_payload_fields

  @doc "The at-rest projection field set (refs + provider id only — never a body)."
  @spec at_rest_fields() :: [atom()]
  def at_rest_fields, do: @at_rest_fields

  @doc """
  The minimal ESP request payload — ONLY the `@provider_payload_fields` whitelist.

  FAIL-CLOSED (INV-1): raises `ArgumentError` if any whitelisted value is still a
  `%Samen.Masked{}` (an unresolved value must NEVER be transmitted) or a binary
  containing a `vt_` vault token (a vault reference must NEVER leak to an ESP). A
  masked/preview render therefore CANNOT be turned into a provider payload — the
  operator preview is un-sendable by construction.
  """
  @spec provider_payload(t()) :: %{optional(atom()) => term()}
  def provider_payload(%__MODULE__{} = rendered) do
    payload = Map.take(Map.from_struct(rendered), @provider_payload_fields)
    :ok = assert_sendable!(payload)
    payload
  end

  @doc """
  The at-rest record projection — the ONLY thing a delivery record persists:
  provider id + template ref + opaque refs. There is structurally no body,
  subject, or address key, so a rendered body cannot reach the DB through this
  projection (spec §C3; ADR-038 §5.4).
  """
  @spec at_rest_record(t()) :: %{optional(atom()) => term()}
  def at_rest_record(%__MODULE__{} = rendered) do
    Map.take(Map.from_struct(rendered), @at_rest_fields)
  end

  # A provider payload must carry resolved plaintext ONLY — never a mask, never a
  # vault token. Anything else is refused before it can reach the wire.
  defp assert_sendable!(payload) do
    Enum.each(payload, fn {field, value} ->
      cond do
        match?(%Masked{}, value) ->
          raise ArgumentError,
                "provider payload field #{inspect(field)} is a %Samen.Masked{} — a masked/" <>
                  "unresolved value must NEVER be transmitted to an ESP (INV-1)"

        is_binary(value) and String.contains?(value, "vt_") ->
          raise ArgumentError,
                "provider payload field #{inspect(field)} contains a vault token (vt_) — a " <>
                  "vault reference must NEVER leak to an ESP (INV-1)"

        true ->
          :ok
      end
    end)

    :ok
  end
end
