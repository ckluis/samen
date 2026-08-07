defmodule Samen.Scopes.Support.CsatSurvey do
  @moduledoc """
  I6 (spec §I6, T79) — the governed CSAT survey request→response loop. Mirrors
  `Samen.Identity.Confirm`'s governed-module posture (ADR-035 §4.2 discipline,
  generalized): the backing `CsatSurveyToken` resource is default-deny
  (`policy always() do forbid_if(always()) end`); every real authorization
  decision for the anonymous survey-response flow lives HERE, in trusted
  Elixir code that calls Ash with `authorize?: false` — never a raw Ash policy
  bypass reachable from the public LiveView (the T78 KB-portal precedent used
  a genuine `bypass` policy for a READ; a single-use WRITE needs the atomic
  consume a trusted module controls — the same choice `Identity.AuthToken` /
  `Fleet.EnrollmentToken` already made).

  ## Why NOT `Samen.Auth.TokenConsume` verbatim

  `TokenConsume.consume_once/3` is hardcoded to `Identity.AuthToken`'s shape
  (a `context` enum column; a `[:id, :credential_id, :context, :consumed_at,
  :sent_to_bidx]` select list) — `CsatSurveyToken` has neither (survey tokens
  are single-purpose: one context, no bounded enum needed). `respond/4` below
  reimplements the SAME atomic discipline (`Ash.bulk_update!/4`, `strategy:
  [:atomic]`, a WHERE clause narrowed to `is_nil(consumed_at) and expires_at >
  now`) tailored to this resource's actual columns — same single-use
  guarantee under concurrency (two callers racing the same digest: only the
  FIRST to commit sees its row match; the second's WHERE no longer matches
  once the first's UPDATE commits), different shape. `Samen.Auth.TokenMint.
  digest/1` IS reused verbatim — it is genuinely generic (a pure SHA-256 hex
  digest, no resource coupling).

  ## Why dispatch is SYNCHRONOUS (mirrors `Samen.Delivery.AuthMailer`)

  Like an auth token, the CSAT survey link's raw value exists ONLY between
  mint and send — persisting it into a durable `oban_jobs` row (the
  `Samen.Delivery.Lifecycle.deliver/2` enqueue seam) would violate that
  invariant (a later retry could not reconstruct an already-minted,
  hashed-at-rest token). `send_survey/2` therefore mints + dispatches in the
  SAME call, reusing `Samen.Delivery.Lifecycle.EmailWorker`'s identical
  env/adapter resolution and the SAME `Samen.Delivery.Chokepoint` every other
  Delivery consumer routes through — fail-honest (Invariant D1: `sent_at` is
  set ⟺ the chokepoint genuinely returned `{:ok, _}`), suppression-checked
  automatically (`Chokepoint.send/2` step 3), never a faked `:sent`.
  """

  alias Samen.Auth.TokenMint
  alias Samen.Delivery.Chokepoint
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.Message
  alias Samen.Delivery.Rendering

  require Ash.Query
  require Logger

  @survey_ttl_seconds 30 * 24 * 60 * 60

  @type mods :: %{required(:csat_survey_token) => module(), required(:csat) => module()}

  @doc """
  Mint a fresh single-use survey token for `ticket` and dispatch it through the
  fail-honest Delivery chokepoint. Best-effort by contract (see
  `Samen.Scopes.Support.CsatSurveyDispatch` — call this only AFTER the
  triggering write already committed, e.g. from an `after_transaction` hook,
  never from inside its own transaction). NEVER raises.

  Returns:
    * `{:ok, :sent}`       — the token was minted AND the chokepoint genuinely
      dispatched (`sent_at` is set on the token row)
    * `{:ok, :blocked}`    — minted, but no delivery adapter is configured
      (honest, never faked to `:sent`)
    * `{:ok, :suppressed}` — minted, but the recipient is suppressed (the
      chokepoint refused BEFORE the adapter's `deliver/2` was ever called)
    * `{:error, reason}`   — the mint itself failed (no token row exists; no
      send was attempted)
  """
  @spec send_survey(mods(), struct(), keyword()) ::
          {:ok, :sent | :blocked | :suppressed} | {:error, term()}
  def send_survey(%{} = mods, ticket, opts \\ []) do
    raw_token = mint_raw_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@survey_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    # Every CsatSurveyToken attribute is `public?: false` (same posture as
    # `Identity.AuthToken`) — a plain `for_create/3` attrs map is refused
    # (`NoSuchInput`, ADR-035 §4.2's own precedent: `Samen.Auth.TokenMint.
    # mint/5` sets AuthToken's private columns the SAME way). `org_id` is the
    # one exception (the `Samen.Resource` core attribute, always accepted).
    mods.csat_survey_token
    |> Ash.Changeset.for_create(:create, %{org_id: ticket.org_id}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:ticket_id, ticket.id)
    |> Ash.Changeset.force_change_attribute(:agent_id, Keyword.get(opts, :agent_id))
    |> Ash.Changeset.force_change_attribute(:token_digest, TokenMint.digest(raw_token))
    |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, token_row} ->
        dispatch(mods, token_row, ticket, raw_token, opts)

      {:error, reason} ->
        Logger.warning(
          "[CsatSurvey] token mint FAILED ticket_id=#{inspect(Map.get(ticket, :id))}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning(
        "[CsatSurvey] send_survey RAISED (primary write unaffected): #{Exception.message(e)}"
      )

      {:error, e}
  end

  @doc """
  Non-mutating preview: is `raw_token` a genuine, PENDING (unconsumed,
  unexpired) survey token? `{:ok, %{token: token}}` or `{:error,
  :invalid_token}` — one generic outcome (expired / already-consumed / unknown
  token all collapse together; no distinguishing oracle, mirroring `Samen.
  Identity.Invite`/`Confirm`'s anti-replay-oracle posture). Never consumes the
  token — `respond/4` does that atomically.
  """
  @spec preview(mods(), String.t()) :: {:ok, map()} | {:error, :invalid_token}
  def preview(%{} = mods, raw_token) when is_binary(raw_token) do
    digest = TokenMint.digest(raw_token)
    now = DateTime.utc_now()

    mods.csat_survey_token
    |> Ash.Query.filter(token_digest == ^digest and is_nil(consumed_at) and expires_at > ^now)
    |> Ash.Query.ensure_selected([:id, :org_id, :ticket_id, :agent_id, :expires_at, :consumed_at])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [token] -> {:ok, %{token: token}}
      [] -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  @doc """
  Respond to a survey: ATOMICALLY consume `raw_token` (single-use — a
  replayed/expired/unknown token is refused, `{:error, :invalid_token}`, and
  NOTHING is written — the reuse red path) then create the `Csat` response row
  in the SAME governed call, `authorize?: false`, addressed by the
  TOKEN-DERIVED `ticket_id`/`agent_id`/`org_id` — never client-supplied.
  `score` must be `1..5` (bounded; `{:error, :invalid_score}` otherwise — the
  token is NOT consumed on this refusal, so a genuine retry with a valid score
  still works).
  """
  @spec respond(mods(), String.t(), integer(), String.t() | nil) ::
          {:ok, term()} | {:error, :invalid_token | :invalid_score | term()}
  def respond(%{} = mods, raw_token, score, comments \\ nil)
      when is_binary(raw_token) and is_integer(score) do
    if score in 1..5 do
      digest = TokenMint.digest(raw_token)

      case consume_once(mods.csat_survey_token, digest) do
        {:ok, token_row} -> create_csat(mods, token_row, score, comments)
        :error -> {:error, :invalid_token}
      end
    else
      {:error, :invalid_score}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp mint_raw_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp dispatch(_mods, token_row, ticket, raw_token, opts) do
    message = %Message{
      send_id: Ash.UUID.generate(),
      org_id: ticket.org_id,
      to_subscriber_id: token_row.id,
      template_id: "csat_survey"
    }

    {subject, text_body, html_body} =
      Rendering.csat_survey_content(raw_token, base_url: Keyword.get(opts, :base_url))

    fallback_config =
      (EmailWorker.adapter_config() || %{})
      |> Map.merge(%{subject: subject, text_body: text_body, html_body: html_body})

    case Chokepoint.send(message,
           fallback_adapter: EmailWorker.resolve_adapter(),
           fallback_config: fallback_config,
           env: EmailWorker.env()
         ) do
      {:ok, _receipt} ->
        mark_sent(token_row)
        {:ok, :sent}

      {:error, :suppressed} ->
        Logger.warning(
          "[CsatSurvey] survey SUPPRESSED at the delivery chokepoint " <>
            "ticket_id=#{ticket.id}"
        )

        {:ok, :suppressed}

      {:error, :adapter_unconfigured} ->
        Logger.warning(
          "[CsatSurvey] OPERATOR ALERT: survey BLOCKED (adapter unconfigured) " <>
            "ticket_id=#{ticket.id}"
        )

        {:ok, :blocked}

      {:error, reason} ->
        Logger.warning(
          "[CsatSurvey] survey delivery FAILED ticket_id=#{ticket.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_sent(token_row) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    token_row
    |> Ash.Changeset.for_update(:mark_sent, %{sent_at: now}, authorize?: false)
    |> Ash.update(authorize?: false)
  rescue
    e ->
      Logger.warning(
        "[CsatSurvey] mark_sent RAISED (send already dispatched): #{Exception.message(e)}"
      )

      :ok
  end

  # The CsatSurveyToken-shaped sibling of `Samen.Auth.TokenConsume.
  # consume_once/3` — see moduledoc for why the shared helper doesn't fit this
  # resource's columns. Same discipline: ONE `Ash.bulk_update!/4` forced to
  # `strategy: [:atomic]` against a query already narrowed to `token_digest ==
  # ^digest and is_nil(consumed_at) and expires_at > ^now`, targeting the
  # `:consume` action — a single SQL `UPDATE ... WHERE ... RETURNING`
  # statement, never a read-then-write race window.
  defp consume_once(csat_survey_token_mod, digest) do
    now = DateTime.utc_now()

    result =
      csat_survey_token_mod
      |> Ash.Query.filter(token_digest == ^digest and is_nil(consumed_at) and expires_at > ^now)
      |> Ash.Query.ensure_selected([:id, :org_id, :ticket_id, :agent_id, :consumed_at])
      |> Ash.bulk_update!(:consume, %{consumed_at: now},
        authorize?: false,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: [row | _]} -> {:ok, row}
      _ -> :error
    end
  end

  defp create_csat(mods, token_row, score, comments) do
    mods.csat
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: token_row.org_id,
        ticket_id: token_row.ticket_id,
        agent_id: token_row.agent_id,
        score: score,
        comments: comments,
        channel: :email,
        responded_at: DateTime.utc_now()
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end
end
