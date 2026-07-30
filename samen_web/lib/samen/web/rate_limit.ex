defmodule Samen.Web.RateLimit do
  @moduledoc """
  The ONE shared rate-limit seam (ADR-038 §6.1) — `check/3` in front of every
  rate-limited web surface. T19 ships the WEBHOOK INGRESS rows (§6.3); T103 adds the
  AUTH surface rows (sign-in, registration, reset-request, TOTP 2FA verify) to this SAME
  module — never a parallel implementation (ADR-038 §6.1 binding).

  ## Mechanism (ADR-038 §6.1, INV-4)

  Manual-plug shape: callers make explicit `Samen.Web.RateLimit` calls in the ingress
  controller / plugs / LiveView hooks — the `ash_rate_limiter` resource-level `rate_limit`
  DSL is NOT used (it would compile limits into core resources). The deps
  (`ash_rate_limiter == 1.0.0` + `hammer ~> 7.0`) live in `samen_web` only;
  `samen_core/mix.exs` stays untouched.

  The counter backend is `Samen.Web.RateLimit.Backend` — a Hammer fixed-window ETS store
  with a STABLE supervised owner (`Samen.Web.Application`). It is a THIN private detail
  (ADR-038 §6.1): swapping it for a Redis/multi-node Hammer backend changes no caller —
  the seam, the key discipline, and the `:ok | {:error, :rate_limited}` return contract
  are the shared contract, the backend is not.

  ## Keys are non-PII by construction (ADR-038 §6.2)

  Bucket key format `"{surface}:{kind}:{value}"` where `value` is a provider name, an
  `email_bidx` (non-reversible keyed-HMAC, ADR-035 §4.1), a credential id, or a remote
  IP — NEVER a plaintext email or any vault-routed value. IP appears only in these
  ephemeral counters (ADR-035 §4.3 posture), never persisted to any resource. Nothing is
  ever keyed on payload contents (untrusted pre-verification).

  ## Auth-surface limits (ADR-035 §4.5 / ADR-038 §6.3; config-tunable)

  | Surface | Per-account key | Per-IP key |
  |---|---|---|
  | `:signin_account` / `:signin_ip` | 10/min per `email_bidx` | 100/hr per IP |
  | `:registration_ip` | — | 5/hr per IP |
  | `:token_request_account` (reset-request / verify resend) | 3/15min per `email_bidx` | — |
  | `:totp_verify_credential` | 5/min per credential id | — |

  Both axes are independent: an IP-rotating attacker is still caught per-account; an
  account-rotating attacker is still caught per-IP. Over-limit → `{:error, :rate_limited}`
  (the surface renders a 429 / interstitial); the check is constant-shape for a known vs
  unknown account, so it introduces no enumeration timing signal (ADR-035 §4.4/§4.5).

  ## Ingress limits (ADR-038 §6.3; T19)

  | Surface | Key | Default | Semantics |
  |---|---|---|---|
  | `:webhook_ingress` | `"webhook:{provider}"` (per-provider AGGREGATE) | 1000/min | Over → 429; providers retry with backoff, no loss |
  | `:webhook_bad_sig` | per remote IP | 60/min | Counted on verification FAILURE only; 429 BEFORE the crypto work |

  Tune via:

      config :samen_web, Samen.Web.RateLimit,
        limits: %{signin_account: {10, 60_000}, signin_ip: {100, 3_600_000}}
  """

  alias Samen.Web.RateLimit.Backend

  # {limit, window_ms} defaults — used when config does not override the surface.
  @default_limits %{
    # Auth surfaces (ADR-035 §4.5 / ADR-038 §6.3; T103).
    signin_account: {10, 60_000},
    signin_ip: {100, 3_600_000},
    registration_ip: {5, 3_600_000},
    token_request_account: {3, 900_000},
    totp_verify_credential: {5, 60_000},
    # Webhook ingress (ADR-038 §6.3; T19).
    webhook_ingress: {1000, 60_000},
    webhook_bad_sig: {60, 60_000},
    # Bounded `auth.login_failed` audit counter (ADR-035 §5 taxonomy / ADR-038 §6.4;
    # T103). NOT a rate limit — a bidx-keyed FAILURE counter: every failed attempt bumps
    # it, but the append-only `aud_event` row is emitted only on a window EDGE (the first
    # failure), so N ≫ limit brute-force attempts produce O(windows) audit rows, not O(N).
    # The tuple's first slot is the window's failure-count ceiling used only to keep the
    # counter cell bounded; the window is 15 min.
    login_failed_audit: {1, 900_000}
  }

  @doc """
  Increment the window counter for `{surface, kind, value}` and enforce the limit.
  Returns `:ok` while at/under the limit, `{:error, :rate_limited}` once over it.

  Use for the per-request flood guard (auth surfaces, `:webhook_ingress`).
  """
  @spec check(atom(), atom(), String.t()) :: :ok | {:error, :rate_limited}
  def check(surface, kind, value) do
    {limit, window_ms} = limit_for(surface)
    ensure_started()

    case Backend.hit(bucket(surface, kind, value), window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after_ms} -> {:error, :rate_limited}
    end
  end

  @doc """
  Peek (no increment) whether `{surface, kind, value}` is already at/over its limit in
  the current window. Use for the PRE-crypto bad-signature gate (`:webhook_bad_sig`) so
  an over-limit attacker is 429'd BEFORE any HMAC work.
  """
  @spec over_limit?(atom(), atom(), String.t()) :: boolean()
  def over_limit?(surface, kind, value) do
    {limit, window_ms} = limit_for(surface)
    ensure_started()
    Backend.get(bucket(surface, kind, value), window_ms) >= limit
  end

  @doc """
  Increment a failure counter for `{surface, kind, value}` WITHOUT enforcing (the
  enforcement is `over_limit?/3` on the next request's pre-crypto gate). Use to count
  verification failures for `:webhook_bad_sig`.
  """
  @spec record_failure(atom(), atom(), String.t()) :: :ok
  def record_failure(surface, kind, value) do
    {_limit, window_ms} = limit_for(surface)
    ensure_started()
    _ = Backend.inc(bucket(surface, kind, value), window_ms, 1)
    :ok
  end

  @doc """
  Increment the window counter for `{surface, kind, value}` and return the NEW count —
  a non-enforcing bump used for EDGE detection (ADR-038 §6.4 bounded audit): the caller
  emits an audit row only when the returned count marks a window edge (e.g. `== 1`, the
  first failure of the window), so a brute-force run updates the bidx-keyed counter every
  attempt but appends O(windows) audit rows, never O(attempts).
  """
  @spec bump(atom(), atom(), String.t()) :: non_neg_integer()
  def bump(surface, kind, value) do
    {_limit, window_ms} = limit_for(surface)
    ensure_started()
    Backend.inc(bucket(surface, kind, value), window_ms, 1)
  end

  @doc "Clear all counters (test support)."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    :ets.delete_all_objects(Backend)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # The non-PII key discipline (§6.2): surface:kind:value — value is provider/ip/bidx/id.
  # Hammer stamps the fixed window internally; this string is the "bucket name" the
  # non-PII probe (done-criterion 2) greps + inspects at runtime.
  defp bucket(surface, kind, value), do: "#{surface}:#{kind}:#{value}"

  @doc """
  The configured `{limit, window_ms}` for `surface` (config override or the
  compiled default). Public so callers needing the SAME numbers the ETS check
  enforces — e.g. `Samen.Identity.LoginFailure.over_limit?/5`'s durable,
  restart-survival re-check (ADR-038 §6.4; T109) — never hardcode a second copy
  that could drift from this module's own `@default_limits`.
  """
  @spec limit_for(atom()) :: {pos_integer(), pos_integer()}
  def limit_for(surface) do
    config = Application.get_env(:samen_web, __MODULE__, [])
    limits = Keyword.get(config, :limits, %{})
    Map.get(limits, surface) || Map.fetch!(@default_limits, surface)
  end

  # Auto-start on first use (the `Samen.FeatureFlags.Cache` house pattern) so the seam
  # works even outside a host that supervises `Samen.Web.Application`. Gate on the ETS
  # TABLE (named after `Backend`), not the process: Hammer's GenServer is not name-
  # registered, but it owns the named table — so in a normal boot the app supervisor
  # already created it and this is a no-op fast path.
  defp ensure_started do
    case :ets.whereis(Backend) do
      :undefined ->
        case Backend.start_link(clean_period: :timer.minutes(1)) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _tid ->
        :ok
    end
  end
end
