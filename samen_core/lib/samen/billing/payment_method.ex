defmodule Samen.Billing.PaymentMethod do
  @moduledoc """
  The vendor-generic B5 payment-method logic (T23; ADR-038 §3.1
  `create_portal_session`, §3.5 no-PAN rule + B5's cross-reference rule).
  `samen_core` owns this logic (INV-4) — the vendor adapter package only
  translates + transports (builds the hosted-session HTTP call, optionally
  syncs the vendor customer object); it never decides org-scoping, attribute
  whitelisting, or what a caller is allowed to hand the provider.

  ## The CORE invariant (spec §B5, ADR-038 §3.5)

  Card-on-file is EXCLUSIVELY via a vendor-HOSTED billing-portal / SetupIntent
  session URL — no card number (PAN) or CVC/CVV EVER transits samen. samen
  stores ONLY the opaque provider-customer-id cross-reference (the Customer
  blueprint's external-reference attribute, T18's documented carve-out);
  Customer PII (`billing_name`/`billing_email`) stays vaulted.

  ## `create_portal_session/2` — validate, org-scope, WHITELIST, delegate

  A thin, validating wrapper around `Samen.Billing.Provider.create_portal_session/2`:

    * required attrs present (`org_id`, `customer_ref`, `return_url`) — a missing
      one refuses BEFORE any provider call (mirrors `Samen.Billing.Checkout`).
    * the return URL is ALWAYS org-scoped (same guard `Checkout.create_session/2`
      applies to its redirect URLs — an `org_id` query param FORCED to the
      AUTHORITATIVE `attrs.org_id`, never trusted from the caller).
    * the outbound attrs are reduced to a CLOSED whitelist before the provider
      ever sees them — `org_id`, `customer_ref`, `return_url`, plus (optionally)
      `billing_name`/`billing_email`. Anything else the caller passed in `attrs`
      is silently dropped HERE, before the adapter boundary — defense in depth
      on top of the adapter's own hardcoded vendor-field whitelist.

  ## Customer sync (done-criterion 3 — the ADR-whitelisted vault-resolved fields)

  `billing_name`/`billing_email` are the ONLY two PII fields the Customer
  blueprint declares (`Samen.Scopes.Billing.Blueprint.define_customer/5`'s PII
  map). When a caller wants the vendor's hosted portal to show the tenant's real
  billing name/email (rather than whatever stale value the vendor already has),
  it resolves those two fields through the GOVERNED read path
  (`Samen.Api.PiiResolution.resolve/4` — tenant-plane, own-org, plaintext; NEVER
  a raw column read, NEVER an operator-plane bypass) and passes the resolved
  plaintext strings in as `attrs[:billing_name]`/`attrs[:billing_email]`. This
  module forwards ONLY those two keys (never any other resolved field, even if
  the caller's map somehow carries more) to the provider; the adapter package
  applies its OWN hardcoded name/email-only whitelist when it builds the vendor
  customer-sync HTTP form — two independent whitelists, no drift, no single
  point of failure. Omitting both is a pure no-op (no wasted sync call); the
  caller decides whether a resolve happened.
  """

  @required_portal_attrs [:org_id, :customer_ref, :return_url]

  # The ADR-038 §3.5-derived customer-sync whitelist (done-criterion 3): the
  # ONLY two PII fields ever forwarded toward the provider for a portal-session
  # customer sync. A CLOSED allow-list (not a blocklist) — anything not named
  # here can never reach the provider through this function, no matter what the
  # caller's `attrs` map contains.
  @sync_whitelist [:billing_name, :billing_email]

  @type portal_opts :: [provider: module(), provider_config: map(), actor: map() | nil]

  @doc """
  Create a hosted billing-portal (or SetupIntent) session for an existing
  Customer. `attrs`: `%{org_id, customer_ref, return_url, billing_name
  (optional, vault-RESOLVED plaintext), billing_email (optional, vault-RESOLVED
  plaintext)}` (ADR-038 §3.1, verbatim `create_portal_session` shape + the B5
  customer-sync whitelist). `opts`: `:provider` (a `Samen.Billing.Provider`
  impl), `:provider_config`, and `:actor` — the acting tenant actor
  (`%{role: ...}`).

  ## Admin-by-construction (PP-5; Batch 2 TENANT-ROLE)

  Opening the hosted portal lets the caller CHANGE the card on file or CANCEL the
  subscription — a billing WRITE in the same class the Ash
  `Samen.Scopes.Billing.Blueprint` gates on `RoleAtLeast(:admin)`. This plain function
  enforces that gate HERE, BY CONSTRUCTION: the caller MUST pass an `:actor` whose role
  ranks at least `:admin` (`Samen.Scope.Role`). A missing actor, a `nil`/unknown role, or
  a `member`/`viewer` is DENIED with `{:error, :unauthorized}` BEFORE any provider call —
  fail-closed, by ROLE (not plane). Defense-in-depth beneath the `SettingsLive` affordance
  gate.

  Returns `{:ok, %{url: hosted_url}}` (ALWAYS a vendor-hosted URL — samen never
  renders a card form, done-criterion 2) or `{:error, reason}` — an authorization
  refusal (`:unauthorized`), a validation refusal, `:not_configured` (fail-honest,
  ADR-014), or the provider's own error.
  """
  @spec create_portal_session(map(), portal_opts()) ::
          {:ok, %{url: String.t()}} | {:error, term()}
  def create_portal_session(attrs, opts) when is_map(attrs) do
    with :ok <- authorize_admin(opts),
         :ok <- validate_portal_attrs(attrs) do
      provider = Keyword.fetch!(opts, :provider)
      provider_config = Keyword.get(opts, :provider_config, %{})
      provider.create_portal_session(whitelisted_attrs(org_scope_return_url(attrs)), provider_config)
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization (admin+ by construction) — the same admin gate every other billing
  # write carries as an Ash `RoleAtLeast(:admin)` policy, enforced here for this plain
  # function. Reads `opts[:actor].role`; absent/nil/member/viewer → deny.

  defp authorize_admin(opts) do
    actor = Keyword.get(opts, :actor)

    if Samen.Scope.Role.at_least?(actor_role(actor), :admin),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp actor_role(actor) when is_map(actor), do: Map.get(actor, :role)
  defp actor_role(_), do: nil

  # ---------------------------------------------------------------------------
  # Validation.

  defp validate_portal_attrs(attrs) do
    missing = Enum.filter(@required_portal_attrs, &blank?(Map.get(attrs, &1)))
    if missing == [], do: :ok, else: {:error, {:missing_attrs, missing}}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ---------------------------------------------------------------------------
  # Org-scoping (same guard shape as `Samen.Billing.Checkout.org_scope_redirects/1`
  # — the `return_url` is a tenant redirect just like checkout's success/cancel_url,
  # so it gets the identical anti-cross-tenant-redirect treatment). Duplicated
  # (not shared code) deliberately: this module never depends on Checkout, and a
  # 6-line URL-query helper is cheap to keep independently correct/tested.

  defp org_scope_return_url(attrs) do
    Map.put(attrs, :return_url, org_scope_url(Map.fetch!(attrs, :return_url), attrs.org_id))
  end

  defp org_scope_url(url, org_id) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    query = Map.put(query, "org_id", to_string(org_id))
    %{uri | query: URI.encode_query(query)} |> URI.to_string()
  end

  # ---------------------------------------------------------------------------
  # The CLOSED attrs whitelist forwarded to the provider (defense in depth on
  # top of the adapter's own hardcoded vendor-field whitelist).

  defp whitelisted_attrs(attrs) do
    (@required_portal_attrs ++ @sync_whitelist)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(attrs, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
