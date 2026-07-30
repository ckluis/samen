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
      "<p>Hello #{html_safe(name)},</p>" <>
        "<p>This message was sent to #{html_safe(to)}.</p>" <>
        "<p>You are receiving it because of activity on your account.</p>"

    {subject, text_body, html_body}
  end

  @doc """
  HTML-escape a recipient/tenant-derived value for safe interpolation into an
  email **HTML body**, via the framework's sanctioned `Phoenix.HTML.Safe`
  mechanism — the SAME protocol `%Samen.Masked{}` already implements
  (`Samen.Masked`'s `defimpl Phoenix.HTML.Safe`). Consequences, both load-bearing:

    * a **plaintext** value on the send plane has every HTML-meaningful character
      (`<`, `>`, `&`, `"`, `'`) entity-encoded, so a `display_name`/`org_name`
      like `O'Brien <script>…</script>` becomes inert text, never executable
      markup (F3 stored-XSS fix, T111);
    * a **`%Samen.Masked{}`** value on an operator-preview plane routes through
      the Masked impl and renders `••••` (never a `vt_` token, never
      double-escaped) — the masking discipline is preserved unchanged.

  Escaping belongs on HTML bodies ONLY. A **text body** is not HTML — escaping
  `<` there would corrupt a legitimate plain-text name — so text bodies keep
  plain `String.Chars` interpolation (which still renders `%Masked{}` as `••••`).
  """
  @spec html_safe(term()) :: String.t()
  def html_safe(value) do
    value
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # The T110 route segment each auth context links to: `GET /verify/:token`,
  # `GET /reset/:token`, `GET /invite/:token` (the token legitimately rides IN
  # the URL path — that is how it arrives; a credential/password never does).
  @auth_link_segments %{email_verify: "verify", password_reset: "reset", invite: "invite"}

  @doc """
  Build the recipient-facing CONTENT (subject + text body + html body) for an
  auth-lifecycle token email (`:email_verify` / `:password_reset` / `:invite`),
  carrying the actionable link to the correct T110 route (`/verify/:token`,
  `/reset/:token`, `/invite/:token`) (F1, T111).

  The raw token rides IN the URL path (that is how it arrives at the browser
  route — the objection is a credential/password appearing in a URL, never a
  bearer token that IS the URL's subject). The link is escaped through
  `html_safe/1` for the HTML body's `href`; the text body carries the bare URL.
  `:base_url` (opt, or `config :samen_core, Samen.Delivery.AuthMailer, base_url:`)
  prefixes the link; absent, the link is a site-relative path (`/verify/<token>`).

  Returns `{subject, text_body, html_body}` — the SAME shape every
  `Samen.Delivery.Rendering` template function returns, so it threads through the
  send path identically.
  """
  @spec auth_content(atom(), String.t(), keyword()) :: {String.t(), String.t(), String.t()}
  def auth_content(context, raw_token, opts \\ [])
      when is_map_key(@auth_link_segments, context) and is_binary(raw_token) do
    base_url = opts |> Keyword.get(:base_url) |> normalize_base_url()
    link = "#{base_url}/#{Map.fetch!(@auth_link_segments, context)}/#{raw_token}"
    {subject, intro, cta} = auth_copy(context)

    text_body =
      intro <>
        "\n\n" <>
        cta <>
        ":\n" <>
        link <>
        "\n\n" <>
        "If you did not request this, you can safely ignore this email.\n"

    html_body =
      "<p>#{intro}</p>" <>
        "<p><a href=\"#{html_safe(link)}\">#{cta}</a></p>" <>
        "<p>If the button above does not work, copy and paste this link into your " <>
        "browser:<br>#{html_safe(link)}</p>" <>
        "<p>If you did not request this, you can safely ignore this email.</p>"

    {subject, text_body, html_body}
  end

  defp auth_copy(:email_verify),
    do:
      {"Verify your email address",
       "Confirm your email address to finish setting up your account.", "Verify email address"}

  defp auth_copy(:password_reset),
    do:
      {"Reset your password", "We received a request to reset your password.",
       "Reset your password"}

  defp auth_copy(:invite),
    do:
      {"You've been invited to join a team",
       "You've been invited to join a team. Accept the invitation to get started.",
       "Accept invitation"}

  defp normalize_base_url(nil), do: ""
  defp normalize_base_url(url) when is_binary(url), do: String.trim_trailing(url, "/")

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
