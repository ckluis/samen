defmodule Samen.Web.Auth.Oidc do
  @moduledoc """
  A6 — the OPTIONAL OIDC framework module (ADR-035 §5 A6; spec §WS-A A6,
  spec-questions c1/c2). Google is the built reference IdP, via the **assent**
  protocol library (ADR-035 §7 — a protocol implementation, NOT a vendor SDK;
  the SAME library `ash_authentication` uses). SAML ships as a documented
  extension seam only (`docs/guides/sso-saml-seam.md`), not an implementation
  (c1 ruling).

  ## Optional by construction (the module-absent contract)

  This module is mounted ONLY when a host passes `oidc:` to
  `Samen.Web.Router.samen_auth_routes/1` (e.g. `samen_auth_routes(oidc:
  [:google], ...)`). An app that does not enable it gets **no** `/auth/oidc`
  routes at all (done-criterion 2) — there is no dead button, no half-wired
  surface.

  ## Fail-honest (ADR-014 / repo CLAUDE.md)

  An unconfigured provider — no entry in `config :samen_web, Samen.Web.Auth.Oidc,
  providers: %{...}`, or an entry missing its `:client_id`/`:client_secret` (or
  a test `:strategy`) — NEVER fabricates a redirect or an `{:ok, _}`. Every entry
  point returns `{:error, :not_configured}`. This is the same discipline
  `Samen.Delivery.Smtp` / `Samen.Files.Storage.S3` follow: a stub that claims
  success is the exact lie the gates sabotage-test for.

  ## The strategy seam (assent is the production adapter; tests stub it)

  The token exchange + claims extraction go through a pluggable **strategy**
  implementing `authorize_url/1` + `callback/2` (assent's `Assent.Strategy`
  shape). Production uses `Assent.Strategy.Google` (resolved lazily behind
  `Code.ensure_loaded?/1`, so `samen_web` compiles whether or not the host has
  fetched assent + its optional `jose`/`req` deps — an absent library is just
  another `:not_configured` state). CI passes a deterministic **stub** strategy
  per provider config (`strategy:` key), so `oidc_test.exs` runs with NO live
  Google and NO HTTP (done-criterion 1).

  ## State/nonce (CSRF + replay defense)

  `authorize_url/2` returns `session_params` (a `state` + `nonce`) the caller
  stashes in the signed session; `handle_callback/4` re-checks the callback's
  `state` against it BEFORE any token exchange — a tampered/missing state is
  `{:error, :invalid_state}` (the §8 red test), a matching one proceeds (the
  positive control). This layer's check is defense-in-depth on top of whatever
  the strategy itself verifies.
  """

  @assent_google Assent.Strategy.Google

  @typedoc "A provider key — an atom (`:google`) or its string form."
  @type provider :: atom() | String.t()

  @doc """
  Whether `provider` is configured (present with the credentials a real sign-in
  needs, or a test `:strategy`). `false` → every entry point fail-honests.
  """
  @spec configured?(provider(), map() | keyword() | nil) :: boolean()
  def configured?(provider, config \\ nil) do
    provider_config(config, provider) != nil
  end

  @doc """
  Build the IdP authorization redirect for `provider`. Returns `{:ok, url,
  session_params}` — the caller redirects the browser to `url` and stashes
  `session_params` (`%{state:, nonce:, ...}`) in the signed session for
  `handle_callback/4`. `{:error, :not_configured}` when the provider is absent
  or its strategy cannot be resolved (assent not compiled + no stub).
  """
  @spec authorize_url(provider(), map() | keyword() | nil) ::
          {:ok, String.t(), map()} | {:error, :not_configured | term()}
  def authorize_url(provider, config \\ nil) do
    with pcfg when not is_nil(pcfg) <- provider_config(config, provider),
         {:ok, strategy} <- resolve_strategy(pcfg),
         {:ok, %{url: url} = res} <- strategy.authorize_url(assent_config(pcfg)) do
      {:ok, url, Map.get(res, :session_params, %{})}
    else
      nil -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Handle the IdP callback for `provider`. Validates the callback `state` against
  the stashed `session_params` (defense-in-depth CSRF/replay guard) BEFORE the
  token exchange, then runs the strategy's `callback/2` and normalizes the
  asserted claims.

  Returns `{:ok, claims}` where `claims` is
  `%{provider:, provider_uid:, email:, first_name:, last_name:, email_verified:}`
  — the shape `Samen.Identity.OidcLink.link_or_provision/3` consumes. Errors:
  `{:error, :not_configured}` (provider absent), `{:error, :invalid_state}`
  (tampered/missing state), `{:error, :no_email}` (the IdP asserted no email —
  nothing to bidx-match), `{:error, reason}` (strategy failure).
  """
  @spec handle_callback(provider(), map(), map(), map() | keyword() | nil) ::
          {:ok, map()} | {:error, :not_configured | :invalid_state | :no_email | term()}
  def handle_callback(provider, params, session_params, config \\ nil)
      when is_map(params) and is_map(session_params) do
    with pcfg when not is_nil(pcfg) <- provider_config(config, provider),
         :ok <- validate_state(params, session_params),
         {:ok, strategy} <- resolve_strategy(pcfg),
         {:ok, %{user: raw_claims}} <-
           strategy.callback(assent_config(pcfg, session_params), params) do
      normalize_claims(provider, raw_claims)
    else
      nil -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- config resolution -------------------------------------------------------

  # Returns the provider's config keyword list ONLY when it is genuinely usable —
  # present AND carrying either real IdP credentials (client_id + client_secret)
  # or an explicit test `:strategy`. Anything less is `nil` → `:not_configured`.
  defp provider_config(config, provider) do
    key = provider_key(provider)

    providers =
      case config do
        nil -> runtime_providers()
        %{} = m -> Map.get(m, :providers, m)
        kw when is_list(kw) -> Keyword.get(kw, :providers, kw)
      end

    pcfg = fetch_provider(providers, key)

    cond do
      pcfg == nil -> nil
      usable?(pcfg) -> pcfg
      true -> nil
    end
  end

  defp fetch_provider(providers, key) when is_map(providers) do
    Map.get(providers, key) || Map.get(providers, Atom.to_string(key))
  end

  defp fetch_provider(providers, key) when is_list(providers) do
    Keyword.get(providers, key)
  end

  defp fetch_provider(_providers, _key), do: nil

  defp usable?(pcfg) do
    has?(pcfg, :strategy) or (has?(pcfg, :client_id) and has?(pcfg, :client_secret))
  end

  defp has?(pcfg, key) do
    case get(pcfg, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp runtime_providers do
    Application.get_env(:samen_web, __MODULE__, [])
    |> Keyword.get(:providers, %{})
  end

  # -- strategy ----------------------------------------------------------------

  # A provider may pin its own `:strategy` (the CI stub, or a specific assent
  # strategy). Otherwise the default is `Assent.Strategy.Google`, resolved
  # lazily: if assent is not compiled in this build, there is no strategy — a
  # `:not_configured` state, never a crash.
  defp resolve_strategy(pcfg) do
    case get(pcfg, :strategy) do
      nil ->
        if Code.ensure_loaded?(@assent_google),
          do: {:ok, @assent_google},
          else: {:error, :not_configured}

      strategy when is_atom(strategy) ->
        {:ok, strategy}
    end
  end

  # The keyword config handed to the strategy. assent's Google/OIDC strategies
  # read `:client_id`/`:client_secret`/`:redirect_uri`; `:session_params` carries
  # the state/nonce back on the callback leg.
  defp assent_config(pcfg, session_params \\ nil) do
    base =
      [
        client_id: get(pcfg, :client_id),
        client_secret: get(pcfg, :client_secret),
        redirect_uri: get(pcfg, :redirect_uri)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    extra = get(pcfg, :strategy_opts) || []

    base = Keyword.merge(base, extra)

    if session_params, do: Keyword.put(base, :session_params, session_params), else: base
  end

  # -- state / claims ----------------------------------------------------------

  defp validate_state(params, session_params) do
    expected = get(session_params, :state) || get(session_params, "state")
    actual = Map.get(params, "state") || Map.get(params, :state)

    cond do
      is_binary(expected) and expected != "" and secure_equal?(expected, actual) -> :ok
      true -> {:error, :invalid_state}
    end
  end

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_equal?(_a, _b), do: false

  # Normalize the IdP's asserted user map (string OR atom keys, per strategy) to
  # the `Samen.Identity.OidcLink` claims shape. A missing email is fatal — the
  # bidx match has nothing to key on.
  defp normalize_claims(provider, raw) do
    email = claim(raw, "email")

    if is_binary(email) and email != "" do
      {:ok,
       %{
         provider: provider_key(provider),
         provider_uid: claim(raw, "sub"),
         email: email,
         first_name: claim(raw, "given_name"),
         last_name: claim(raw, "family_name"),
         email_verified: claim(raw, "email_verified")
       }}
    else
      {:error, :no_email}
    end
  end

  # Read a claim by its string key, falling back to the atom key — WITHOUT
  # coercing a legitimate `false` to `nil`. `Map.get(k) || Map.get(atom_k)` is
  # WRONG here: `false || x == x`, so an explicit `email_verified: false` (the
  # unverified-email signal the §5 A6 security check depends on) would be
  # destroyed at normalization before any consumer ever sees it. `Map.fetch`
  # distinguishes a PRESENT `false` from an ABSENT key.
  defp claim(raw, key) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, value} -> value
      :error -> Map.get(raw, String.to_atom(key))
    end
  end

  # -- small utilities ---------------------------------------------------------

  defp provider_key(p) when is_atom(p), do: p
  defp provider_key(p) when is_binary(p), do: String.to_existing_atom(p)

  defp get(cfg, key) when is_map(cfg), do: Map.get(cfg, key)
  defp get(cfg, key) when is_list(cfg), do: cfg[key]
  defp get(_cfg, _key), do: nil
end
