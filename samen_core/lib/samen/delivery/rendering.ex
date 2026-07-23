defmodule Samen.Delivery.Rendering do
  @moduledoc """
  PII-safe email rendering (C3, T29) — the vendor-generic CORE seam that turns a
  token-only `Samen.Delivery.Message` into a `Samen.Delivery.RenderedEmail` by
  resolving the recipient's address (and any vault-routed body fields) THROUGH
  `Samen.Api.PiiResolution` on the actor's plane. This is the INV-1 load-bearing
  render path: the recipient of an email legitimately needs plaintext (the mail is
  addressed TO them), so the **send plane resolves plaintext**; an operator
  previewing the same message holds no reveal grant, so the **operator plane
  masks** (`••••`).

  ## Why this lives in core (INV-4)

  Rendering is vendor-generic: it resolves fields through the single governed read
  path and interpolates them into a template. No ESP is special-cased and no vendor
  dep is pulled — the three first-party-but-separate adapter packages (ADR-038 §8)
  call `render_for_send/4` + `RenderedEmail.provider_payload/1` to obtain the
  minimal payload rather than hand-revealing/hand-masking inside `deliver/2`. Core
  stays green with every adapter absent.

  ## Never bypass PiiResolution, never hand-mask

  Every field that could be PII is resolved by `Samen.Api.PiiResolution.resolve/4`
  — the SAME seam every framework read surface (list/detail reads, CSV export
  cells, search projections, the notifications inbox) runs on. This module holds NO
  masking logic of its own; the plane decides, the resolver masks. On the send
  plane a vault-routed field resolves to plaintext (the recipient owns the mail);
  on an operator-preview plane it stays `%Samen.Masked{}` unless a reveal grant
  covers the subject.

  ## Composing the T28 send path

  `render_for_send/4` is what the `Samen.Delivery.Chokepoint` send path (and the
  ESP adapters it routes to) call to build the recipient-facing payload — see
  `Samen.Delivery.Chokepoint.render_for_send/4`, which delegates here.
  `preview_for_operator/4` renders the SAME message on the operator plane for an
  operator-facing preview surface, where it masks.

  ## The template

  `render/5` interpolates the resolved fields into a template function
  (`:template` opt; a sane vendor-generic default otherwise). Interpolating a
  resolved value uses `String.Chars`, so a `%Masked{}` renders `••••` in the body
  automatically — the mask is the field's normal value, not a special case here.
  A host/adapter supplies its real templates via the `:template` opt.
  """

  alias Samen.Api.PiiResolution
  alias Samen.Delivery.{Message, RenderedEmail}
  alias Samen.Masked

  @default_address_field :emails
  @default_name_field :display_name

  @doc """
  Render `message`'s recipient-facing email on the **send/recipient plane** — the
  recipient legitimately receives their own plaintext address and body. Returns a
  `Samen.Delivery.RenderedEmail` whose vault-routed fields are resolved CLEAR.

  `recipient` is the loaded recipient record (the vault subject); `resource` is its
  Ash resource module. `opts` thread through to the resolver (`:repo` required for
  a real decrypt; `:vault`/`:grant` injectable for tests) plus the render knobs
  (`:address_field`, `:name_field`, `:template`).
  """
  @spec render_for_send(Message.t(), struct(), module(), keyword()) :: RenderedEmail.t()
  def render_for_send(%Message{} = message, recipient, resource, opts \\ []) do
    render(message, recipient, resource, send_plane_actor(), opts)
  end

  @doc """
  Render the SAME `message` on the **operator-preview plane** — an impersonating
  operator holds no reveal grant, so every vault-routed field renders `%Masked{}`
  (`••••`). Use this for any operator-facing preview of a sent message. The result
  is un-sendable by construction: `RenderedEmail.provider_payload/1` refuses a
  masked payload (INV-1).
  """
  @spec preview_for_operator(Message.t(), struct(), module(), keyword()) :: RenderedEmail.t()
  def preview_for_operator(%Message{} = message, recipient, resource, opts \\ []) do
    render(message, recipient, resource, operator_plane_actor(), opts)
  end

  @doc """
  Render `message` on an explicit plane `actor` (a `%{plane: ...}` map, the same
  actor shape `Samen.Api.PiiResolution` reads). Resolves the recipient record's
  vault-routed fields on that plane and interpolates them into the template.
  Prefer `render_for_send/4` / `preview_for_operator/4`.
  """
  @spec render(Message.t(), struct(), module(), map(), keyword()) :: RenderedEmail.t()
  def render(%Message{} = message, recipient, resource, actor, opts) when is_map(actor) do
    address_field = Keyword.get(opts, :address_field, @default_address_field)
    name_field = Keyword.get(opts, :name_field, @default_name_field)
    template_fun = Keyword.get(opts, :template, &default_template/1)

    [resolved] = PiiResolution.resolve([recipient], resource, actor, resolve_opts(opts))

    to = Map.get(resolved, address_field)
    name = Map.get(resolved, name_field)

    {subject, text_body, html_body} =
      template_fun.(%{to: to, name: name, template_ref: message.template_id})

    %RenderedEmail{
      send_id: message.send_id,
      template_ref: message.template_id,
      to_subscriber_id: message.to_subscriber_id,
      to: to,
      subject: subject,
      text_body: text_body,
      html_body: html_body,
      provider_message_id: nil,
      vault_token_ref: token_ref(recipient, address_field)
    }
  end

  @doc """
  The vendor-generic default template. A host/adapter overrides it via the
  `:template` opt with its real subject/body. Interpolating `to` uses
  `String.Chars`, so a masked address renders `••••` in the body with no special
  casing.
  """
  @spec default_template(map()) :: {String.t(), String.t(), String.t()}
  def default_template(%{to: to, name: name}) do
    subject = "Your account update"

    text_body =
      "Hello #{name},\n\n" <>
        "This message was sent to #{to}.\n" <>
        "You are receiving it because of activity on your account.\n"

    html_body =
      "<p>Hello #{name},</p>" <>
        "<p>This message was sent to #{to}.</p>" <>
        "<p>You are receiving it because of activity on your account.</p>"

    {subject, text_body, html_body}
  end

  # Only the resolver-relevant opts flow to PiiResolution.resolve/4.
  defp resolve_opts(opts), do: Keyword.take(opts, [:repo, :vault, :grant])

  # The recipient's OWN vault token, captured for internal correlation only. It is
  # NEVER placed in the provider payload — the payload-minimality gate proves so.
  defp token_ref(recipient, field) do
    case Map.get(recipient, field) do
      %Masked{token: token} -> token
      _ -> nil
    end
  end

  # The canonical per-plane actor shapes (mirror `Samen.MaskingCase.plane_actor/1`
  # and the api_key auth resolver): the send/recipient plane is the tenant's own
  # plane (PII clear); the operator-preview plane is an impersonation session with
  # no reveal grant (PII masked).
  defp send_plane_actor, do: %{plane: :tenant}

  defp operator_plane_actor,
    do: %{plane: :operator, impersonation: %{session_id: "operator-preview"}}
end
