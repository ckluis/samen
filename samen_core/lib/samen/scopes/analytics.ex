defmodule Samen.Scopes.Analytics do
  @moduledoc """
  The **Analytics** scope (WS-B / G12; ADR-021) — the governed, token-blind
  product-analytics event ledger.

  Ships as a library-authored blueprint (ADR-004): `use`-ing this module inside a
  host's Ash domain expands into one host-owned resource in the host's namespace —
  `<Namespace>.ProductEvent` (`pae`) — a normal `use Samen.Resource` with the host's
  `otp_app`, `repo`, and `domain`. Its columns catalogue into the host's
  `tam_table`/`fld_field`; the host verifiers scan it; it mirrors through the
  vault-excluded CDC projection for free.

  ## The moat — token-blind by construction (ADR-021 §3)

  `pae` carries only bounded ids / enums / a per-subject HMAC pseudonym token / a
  structurally-validated bounded map / timestamps — no `pii do` block, no subject
  identity column. Rows are written ONLY through `Samen.Analytics.track/1`, which
  validates the event name against the bounded `Samen.Analytics.Catalog` and refuses
  any PII-bearing payload at the CAPTURE boundary (dropped + logged, never
  persisted). So a name/email/freeform value never reaches the ledger, the CDC
  projection returns all columns, and erasure is free (the subject's KMS DEK
  destruction renders `pae_actor_ref` unlinkable across live + mirror at once).

  ## Mounting Analytics (the host side)

      defmodule Demo.Analytics do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Analytics,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Analytics
      end

  This defines `Demo.Analytics.ProductEvent` (`pae`). The macro does NOT invent
  abbrevs — the default (`pae`) is registered under the host module name in
  `samen_core/priv/abbrev_registry.json`; verticals mounting the scope add their
  OWN fresh abbrev (ADR-006 append-only, one-owner-forever).

  ## `pae_props` clearance (the honest by-construction claim)

  `pae_props` is a `:map` column. The CDC projection default-denies freeform maps —
  so to keep `pae` fully projectable (AC-G12-3: `project/1` returns ALL columns) the
  host registers `pae_props` (and the bounded string label columns) as `non_pii!`.
  This is honest, not a loophole: `track/1` GUARANTEES by capture-time refusal that
  no PII value enters `props` (the two "reviewers" being the catalog key schema + the
  `Samen.Pii` value oracle). The clearance records that guarantee at the physical
  tier so the token-blind projection covers `pae` end-to-end.
  """

  @default_abbrevs %{product_event: "pae"}

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    product_event_mod = Module.concat(namespace, ProductEvent)

    quote do
      require Samen.Scopes.Analytics.Blueprint

      # Register the Analytics resource in the host domain.
      resources do
        resource(unquote(product_event_mod))
      end

      # Materialize the resource module in the host namespace.
      Samen.Scopes.Analytics.Blueprint.define_product_event(
        unquote(product_event_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.product_event)
      )
    end
  end

  # Resolve the abbrev overrides to a plain %{atom => string} map AT EXPANSION TIME,
  # so the blueprint macro receives a LITERAL abbrev string (the Primitives pattern).
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    overrides =
      pairs
      |> Enum.map(fn {k, v} -> {k, Macro.expand(v, caller)} end)
      |> Map.new()

    Map.merge(@default_abbrevs, overrides)
  end

  defp resolve_abbrevs(_other, _caller), do: @default_abbrevs
end
