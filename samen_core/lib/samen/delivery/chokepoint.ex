defmodule Samen.Delivery.Chokepoint do
  @moduledoc """
  THE single send-lifecycle chokepoint (ADR-038 §4.3/§4.1; C2, T28). This is the
  ONLY module in `samen_core` that calls `Samen.Delivery.Provider.deliver/2` for a
  lifecycle/transactional/marketing/notification send — `Samen.Scopes.Marketing.SendWorker`,
  `Samen.Delivery.Lifecycle.EmailWorker`, `Samen.Delivery.AuthMailer`, and
  `Samen.Notifications.EmailDispatchWorker` all route through `send/2` rather than
  resolving+calling an adapter themselves. A grep for `\\.deliver\\(` under
  `samen_core/lib` (excluding this file, `provider_conformance_case.ex` — the
  ADAPTER conformance harness, which legitimately exercises `deliver/2` directly to
  test an adapter in isolation — and the adapter implementations themselves, which
  only DEFINE `deliver/2`) must return no hits. That grep is the anti-tautology
  proof for "no send path bypasses the chokepoint": reintroduce a raw
  `adapter.deliver(...)` call anywhere else in a consumer and the probe flips.

  ## What `send/2` does, in order

  1. **Resolve the provider** for `message.org_id`: `Samen.Delivery.ProviderSelection`
     first (host default + per-org override among the real ESP adapters, ADR-038
     §4.3) — THIS is what kills the stale `:blocked` terminal for a properly
     configured provider (T27 shipped `ProviderSelection` but left it unwired; this
     is that wiring). When `ProviderSelection` resolves nothing anywhere (host
     never configured `:delivery_provider`), falls back to the caller's LEGACY
     per-worker `:adapter`/`:adapter_config` config (`opts[:fallback_adapter]` /
     `opts[:fallback_config]`) — preserving every existing test/host that wires
     `config :samen_core, Samen.Scopes.Marketing.SendWorker, adapter: ...` directly.
  2. **Decide** (`decide/3`, ADR-014 §3, unchanged semantics): no adapter (or an
     adapter whose `configured?/1` is false) in a non-`:test` env is `:blocked`
     (`{:error, :adapter_unconfigured}`) — NEVER a fake `{:ok, _}`. In `:test` a
     `nil` adapter resolves to `Samen.Delivery.LocalSink` (honest capture).
  3. **Suppression** (spec C2; cosmetic ruling c9 — enforced at the SINGLE
     chokepoint, not duplicated per send family): `suppressed?/2` consults an
     OPTIONAL, host-injectable check module keyed on `(org_id, to_subscriber_id)`.
     Unwired → honestly open (`false`, nothing to check against — mirrors
     `Samen.Notifications.Engine.suppressed?/5`'s unwired-degrades-open precedent).
     A check that RAISES fails CLOSED (refuses the send) — unlike the "no check
     configured" case, a check that exists but breaks must never silently let a
     send through. A suppressed recipient is refused BEFORE `deliver/2` is ever
     called — the adapter never sees a suppressed message.
  4. **Deliver**: only now is `adapter.deliver(message, config)` called. The
     receipt (with `:provider_message_id` when the provider returns one, ADR-038
     §4.1) is returned to the caller, which persists it onto ITS OWN delivery
     record (each family owns its own persistence shape — marketing's `Send` row,
     a `Notification` row, or nothing for the intentionally-stateless lifecycle/
     auth paths).

  ## Configuration

      config :samen_core, Samen.Delivery.Chokepoint,
        suppression_module: MyApp.DeliverySuppression  # optional; suppressed?/2

  ## Provider-agnostic by construction

  Nothing here special-cases an ESP. `resolve_provider/3` returns whatever
  `{module, config}` `ProviderSelection`/the legacy fallback names; `decide/3` and
  `send/2` treat every conformant `Samen.Delivery.Provider` identically — any of
  the three first-party-but-separate adapter packages (ADR-038 §8.1), the T27
  fake, `LocalSink`, or the `Smtp`/`Api` skeletons.
  """

  require Logger

  alias Samen.Delivery.{Message, ProviderSelection, Rendering}

  @doc """
  Pure fail-honest decision (ADR-014 §3; unchanged from the pre-T28 per-worker
  copies — `SendWorker`/`EmailWorker` now `defdelegate` here so this is the ONE
  copy of the logic, not three).

    * `{:blocked, :adapter_unconfigured}` — no adapter, or an unconfigured adapter,
      in a non-`:test` env. The caller MUST treat this as blocked, NEVER sent.
    * `{:deliver, adapter, config}` — route to `adapter.deliver/2`.

  In `:test` a `nil` adapter resolves to `Samen.Delivery.LocalSink` (honest
  capture); the sink is NEVER the fallback in any other env.
  """
  @spec decide(module() | nil, map(), atom()) ::
          {:blocked, :adapter_unconfigured} | {:deliver, module(), map()}
  def decide(nil, _config, :test), do: {:deliver, Samen.Delivery.LocalSink, %{}}
  def decide(nil, _config, _env), do: {:blocked, :adapter_unconfigured}

  def decide(adapter, config, _env) when is_atom(adapter) do
    if adapter.configured?(config) do
      {:deliver, adapter, config}
    else
      {:blocked, :adapter_unconfigured}
    end
  end

  @doc """
  Resolve the `{adapter, config}` pair a send for `org_id` should use:
  `ProviderSelection.resolve!/1` first (per-org override → host default among the
  real ESP adapters), then the caller-supplied legacy fallback. Returns `nil` when
  NEITHER resolves anything (the honest "not wired anywhere" case — `decide/3`
  turns that into `:blocked` outside `:test`).
  """
  @spec resolve_provider(String.t() | nil, module() | nil, map()) :: {module(), map()} | nil
  def resolve_provider(org_id, fallback_adapter, fallback_config) do
    case ProviderSelection.resolve!(org_id) do
      {module, config} -> {module, config}
      nil when is_atom(fallback_adapter) and not is_nil(fallback_adapter) ->
        {fallback_adapter, fallback_config || %{}}
      nil ->
        nil
    end
  end

  @doc """
  THE chokepoint entry point. Resolves the provider, decides fail-honestly, checks
  suppression, and — only if all three pass — calls `adapter.deliver(message, config)`.

  ## Options

    * `:fallback_adapter` / `:fallback_config` — the caller's legacy per-worker
      config (used only when `ProviderSelection` resolves nothing for this org)
    * `:env` — the active delivery env (`:test` enables the `LocalSink` fallback)

  ## Returns

    * `{:ok, receipt}` — a configured, unsuppressed provider genuinely dispatched
    * `{:error, :adapter_unconfigured}` — blocked (ADR-014 §3; never faked to `:ok`)
    * `{:error, :suppressed}` — the recipient is on this org's suppression list;
      `deliver/2` was NEVER called
    * `{:error, reason}` — the provider itself refused/failed
  """
  @spec send(Message.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send(%Message{} = message, opts \\ []) do
    env = Keyword.get(opts, :env, :prod)
    fallback_adapter = Keyword.get(opts, :fallback_adapter)
    fallback_config = Keyword.get(opts, :fallback_config, %{})

    {adapter, config} =
      case resolve_provider(message.org_id, fallback_adapter, fallback_config) do
        nil -> {nil, %{}}
        pair -> pair
      end

    case decide(adapter, config, env) do
      {:blocked, reason} ->
        {:error, reason}

      {:deliver, adapter, config} ->
        if suppressed?(message.org_id, message.to_subscriber_id) do
          {:error, :suppressed}
        else
          adapter.deliver(message, config)
        end
    end
  end

  @doc """
  Is `(org_id, subscriber_id)` suppressed? Unwired (no `:suppression_module`
  configured) degrades to `false` — an honest "no suppression list exists for this
  send family yet" (mirrors `Samen.Notifications.Engine.suppressed?/5`'s unwired
  default). A configured check that RAISES fails CLOSED (`true`) — a broken check
  must never silently let a send through.
  """
  @spec suppressed?(String.t() | nil, String.t() | nil) :: boolean()
  def suppressed?(org_id, subscriber_id) do
    case suppression_module() do
      nil ->
        false

      mod ->
        try do
          mod.suppressed?(org_id, subscriber_id) == true
        rescue
          e ->
            Logger.warning(
              "[Delivery.Chokepoint] suppression check RAISED — failing CLOSED " <>
                "(refusing the send): #{Exception.message(e)}"
            )

            true
        end
    end
  end

  defp suppression_module do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:suppression_module)
  end

  @doc """
  Render the recipient-facing email for a `message` on the SEND path (C3, T29).

  This is the render step of the send path: the recipient legitimately receives
  their own plaintext, so it resolves the recipient's vault-routed fields CLEAR on
  the send plane THROUGH `Samen.Api.PiiResolution` (never hand-masked, never
  bypassed) and returns a `Samen.Delivery.RenderedEmail`. An adapter transports
  `Samen.Delivery.RenderedEmail.provider_payload/1` (the ADR-whitelisted minimal
  payload — never a `vt_` token); a delivery record persists
  `Samen.Delivery.RenderedEmail.at_rest_record/1` (provider id + template ref +
  refs — never the rendered body). Delegates to `Samen.Delivery.Rendering` so the
  masking discipline lives in ONE vendor-generic seam.

  An operator previewing the same message uses
  `Samen.Delivery.Rendering.preview_for_operator/4` instead — the SAME record on
  the operator plane, where it masks.
  """
  @spec render_for_send(Message.t(), struct(), module(), keyword()) ::
          Samen.Delivery.RenderedEmail.t()
  defdelegate render_for_send(message, recipient, resource, opts \\ []), to: Rendering
end
