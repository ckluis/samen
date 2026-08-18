defmodule Samen.Delivery.AuthMailer do
  @moduledoc """
  ADR-035 §5 A2/A3/A5 — dispatch auth-lifecycle token emails (`:email_verify`,
  `:password_reset`, `:invite`) through the SAME fail-honest Delivery
  chokepoint transactional lifecycle mail uses (`Samen.Delivery.Lifecycle.EmailWorker`),
  honoring its CURRENT `:blocked` state exactly (ADR-014 §3, Invariant D1):
  `:test` env with no configured adapter captures via `Samen.Delivery.LocalSink`
  (honest "captured, not delivered"); any other env with no configured adapter
  is honestly `:blocked` (an `{:error, _}`, NEVER faked to `:sent`) — real ESP
  wiring is the same Phase 2 operator TODO already documented on
  `Samen.Delivery.Smtp`/`Samen.Delivery.Api`.

  ## Why NOT `Samen.Delivery.Lifecycle.deliver/2` (the Oban-durable enqueue seam)

  An auth token's RAW value exists ONLY between mint and send (ADR-035 §4.2 —
  "never persisted, never logged"). `Lifecycle.deliver/2` persists its args to
  a durable `oban_jobs` row for async retry — carrying the raw token through
  that row would violate the "never persisted" invariant; carrying nothing
  would leave a later retry unable to reconstruct an already-minted,
  hashed-at-rest token (only its SHA-256 digest survives). This module
  therefore dispatches SYNCHRONOUSLY, in the SAME call that minted the token,
  reusing `EmailWorker`'s identical env/adapter-resolution + fail-honest
  `decide/3` branching directly (the SAME chokepoint, not a fork of it) — a
  host that has wired ONE delivery adapter gets auth mail through it for
  free, with the exact same `:blocked` semantics.

  The raw token is NEVER threaded into any PERSISTED struct here: the
  token-only `%Message{}` (what gets logged/persisted to a delivery record)
  stays token/PII-free. The raw token lives only on the caller's stack and in
  the transient, non-persisted delivery CONTENT this module renders through
  `Samen.Delivery.Rendering.auth_content/3` (subject + text/html body + the
  actionable `/verify|/reset|/invite` link, F1/T111) and threads onto the send
  config — the SAME seam `Samen.Notifications.Digest` uses to carry rendered
  digest content: `LocalSink` captures it in test, a real adapter consumes it
  in prod. `Smtp`/`Api` are still skeletons returning
  `{:error, :not_implemented}`/`{:error, :not_configured}`, so no genuinely
  delivered email exists yet in a non-test env — captured by `LocalSink` in
  test, honestly blocked everywhere else, exactly per the task contract. A
  caller that does not thread a `:raw_token` gets a bare send (no content) —
  never a crash.
  """

  require Logger

  alias Samen.Delivery.Chokepoint
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.Message
  alias Samen.Delivery.Rendering

  @contexts [:email_verify, :password_reset, :invite]

  @doc "The bounded set of auth-token email contexts this mailer accepts."
  @spec contexts() :: [atom()]
  def contexts, do: @contexts

  @doc """
  Dispatch an auth-token email through the fail-honest chokepoint.

  `opts`:
    * `:org_id` — owning org UUID (nilable; a password-reset request is
      org-less at the Credential level, so `nil` is valid and expected there)
    * `:credential_id` — the Credential the token belongs to (REQUIRED for
      `:email_verify`/`:password_reset`)
    * `:invitation_id` — the `Identity.Invitation` the token belongs to
      (REQUIRED for `:invite` — an invite has no Credential yet; the
      recipient is resolved from the invitation row at real-send time, the
      SAME "reveal at send" discipline every other Delivery consumer uses)
    * `:raw_token` — the freshly-minted raw auth token. When present, this
      module renders real content (subject + text/html body + the actionable
      `/verify|/reset|/invite` link) via `Samen.Delivery.Rendering.auth_content/3`
      and threads it onto the send config. When absent, the send carries no
      rendered content (bare token-only envelope) — never a crash.
    * `:base_url` — optional link prefix (falls back to
      `config :samen_core, Samen.Delivery.AuthMailer, base_url:`, then a
      site-relative path).

  Returns `{:ok, receipt}` (a `LocalSink` capture in `:test`, or a genuinely
  configured adapter's receipt) or `{:error, :adapter_unconfigured | reason}`
  — a blocked send is ALWAYS an `:error`, never a faked `:ok` (Invariant D1).
  """
  @spec dispatch(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(context, opts) when context in @contexts do
    subscriber_id =
      case context do
        :invite -> Keyword.fetch!(opts, :invitation_id)
        _ -> Keyword.fetch!(opts, :credential_id)
      end

    message = %Message{
      send_id: Ecto.UUID.generate(),
      org_id: Keyword.get(opts, :org_id),
      to_subscriber_id: subscriber_id,
      template_id: to_string(context)
    }

    case Chokepoint.send(message,
           fallback_adapter: EmailWorker.resolve_adapter(),
           fallback_config: dispatch_config(context, opts),
           env: EmailWorker.env()
         ) do
      {:error, :adapter_unconfigured} = err ->
        Logger.warning(
          "[AuthMailer] OPERATOR ALERT: auth token email BLOCKED (adapter unconfigured) " <>
            "context=#{context} subscriber_id=#{subscriber_id}"
        )

        err

      {:error, :suppressed} = err ->
        Logger.warning(
          "[AuthMailer] auth token email SUPPRESSED at the delivery chokepoint " <>
            "context=#{context} subscriber_id=#{subscriber_id}"
        )

        err

      other ->
        other
    end
  end

  # The rendered auth-email content rides on the send config the SAME way
  # `Samen.Notifications.Digest` threads its digest content — merged ONTO the
  # configured adapter's config (`LocalSink` captures it in test; a real adapter
  # consumes it in prod). Built ONLY when a `:raw_token` is threaded through; a
  # tokenless caller gets the bare adapter config (no content, no crash).
  defp dispatch_config(context, opts) do
    base = EmailWorker.adapter_config() || %{}

    case Keyword.get(opts, :raw_token) do
      token when is_binary(token) ->
        {subject, text_body, html_body} =
          Rendering.auth_content(context, token, base_url: base_url(opts))

        Map.merge(base, %{subject: subject, text_body: text_body, html_body: html_body})

      _ ->
        base
    end
  end

  defp base_url(opts) do
    Keyword.get(opts, :base_url) ||
      Application.get_env(:samen_core, __MODULE__, [])[:base_url] || ""
  end
end
