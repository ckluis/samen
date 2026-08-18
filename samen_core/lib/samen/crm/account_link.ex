defmodule Samen.CRM.AccountLink.Config do
  @moduledoc """
  Host-supplied wiring for `Samen.CRM.AccountLink` (T160, spec §I4's per-account
  "unfair advantage" seam). Mirrors `Samen.Mailbox.Config`'s shape: every field is
  host-authoritative, and `:org_id` is the trusted tenant boundary (from the caller's
  own `Samen.Scope`, never from the CRM `Company` row being resolved).
  """

  @enforce_keys [:org_id, :repo, :customer_resource]
  defstruct [:org_id, :repo, :customer_resource, max_match_candidates: 500]

  @type t :: %__MODULE__{
          org_id: String.t(),
          repo: Ecto.Repo.t(),
          customer_resource: module(),
          max_match_candidates: pos_integer()
        }
end

defmodule Samen.CRM.AccountLink do
  @moduledoc """
  T160 (operator ruling 2026-08-06, from the T77 design refutation) — the REAL linkage
  seam between a CRM `Company` and the SAME tenant's own `Billing.Customer` row. Per
  `Samen.Web.AccountHealth`'s (T77) proven finding: the tenant Billing/Support scopes
  hold the org's OWN customer book — the SAME population `CRM.Company` describes — so a
  specific Company genuinely CAN be pointed at a specific Customer; T77 only refuted
  doing so WITHOUT a real seam. This module IS that seam.

  Two resolution mechanisms, tried in order, EXACTLY mirroring `Samen.Mailbox.Match`'s
  fail-closed shape (T74):

    1. **The registered anchor** (authoritative) — `Company.custom["billing_customer_id"]`,
       a Tier-1 custom field registered via `Samen.CustomFields.define_field/2`
       (`ensure_registered!/3` below) — ZERO migration, the ADR-041 `crm_refs`
       precedent (a registered custom-bag key, not a raw-SQL preservation bag). When
       set, this is authoritative: the fallback below is NEVER consulted, even if it
       would resolve to a DIFFERENT customer. A set-but-broken anchor (wrong org, or
       pointing at nothing) resolves to honest absence, never a silent re-guess via
       domain.

    2. **The domain-match fallback** (only when no anchor is set) — `Company.domain`
       (a plain, non-PII column) against each org candidate `Billing.Customer`'s
       `billing_email` DOMAIN. `billing_email` is vault-routed (`:pii_email`), so
       comparison runs through the SAME governed read seam every other surface uses:
       org-pinned bounded candidate read → `Samen.Api.PiiResolution.resolve/4` on the
       TENANT plane (the org reads its own customers' PII in clear; no reveal grant
       minted, the vault is never touched directly) → normalized-domain comparison
       (`Samen.Mailbox.Match.normalize/1`/`domain/1`, reused verbatim — same
       normalization the T74 mailbox match already uses). FAIL-CLOSED: zero matching
       candidates is honest absence; TWO OR MORE matching candidates is ALSO honest
       absence (an ambiguous match is never resolved by guessing) — never a
       wrong-account link.

  This module NEVER calls the vault's own reveal function and never unwraps a `%Masked{}` — if
  PII resolution comes back masked (an actor/plane that may not read the org's own
  customer PII), that candidate simply does not match.

  ## Org pin (the T74 lesson — never let a domain coincidence cross tenants)

  Every candidate read is filtered `org_id == ^config.org_id`, `authorize?: false`
  (the org boundary is pinned from the TRUSTED caller-supplied config, exactly as
  `Samen.Mailbox.Match.candidate_people/1` pins from `config.org_id`, never from
  untrusted row data) — a Company whose domain happens to match a DIFFERENT org's
  billing customer can never resolve to that customer; it is simply not a candidate.
  """

  require Ash.Query

  alias Samen.Api.PiiResolution
  alias Samen.CRM.AccountLink.Config
  alias Samen.CustomFields

  @anchor_field "billing_customer_id"

  @doc "The Tier-1 custom-bag key name this module reads/writes (`\"billing_customer_id\"`)."
  @spec anchor_field() :: String.t()
  def anchor_field, do: @anchor_field

  @doc """
  Register the `billing_customer_id` Tier-1 custom field for `org_id` on
  `company_resource`'s physical table (derived at runtime via `Samen.Catalog.table_name/1`
  — no hardcoded host table name, works for ANY host mounting the CRM scope). Idempotent
  (`define_field/2` is an upsert) — safe to call on every write. ZERO migration: this is
  the ADR-041 `crm_refs` precedent's sibling, a REGISTERED anchor (unlike `crm_refs`,
  which is a migration-only raw-SQL preservation bag Ash itself refuses to write) — so,
  unlike `crm_refs`, an ordinary Ash `:update` action accepts this key once registered.
  """
  @spec ensure_registered!(binary(), module(), Ecto.Repo.t()) :: :ok
  def ensure_registered!(org_id, company_resource, repo) do
    {:ok, _row} =
      CustomFields.define_field(
        %{
          org_id: org_id,
          table_name: Samen.Catalog.table_name(company_resource),
          field_name: @anchor_field,
          type: :string
        },
        repo
      )

    :ok
  end

  @doc """
  Resolve `company` to its linked `Billing.Customer`, per the moduledoc's two-mechanism,
  fail-closed contract. `{:ok, customer, :anchor | :domain}` or `{:error, :not_linked}` —
  the ONLY two outcomes; there is no third "maybe" answer, and this function never
  raises (every read path fails closed to `:not_linked`).
  """
  @spec resolve(struct(), Config.t()) :: {:ok, struct(), :anchor | :domain} | {:error, :not_linked}
  def resolve(company, %Config{} = config) do
    case anchor_id(company) do
      nil -> domain_match(company, config)
      id -> anchor_match(id, config)
    end
  end

  # ---------------------------------------------------------------------------
  # Mechanism 1 — the registered anchor (authoritative; the fallback is NEVER
  # consulted once an anchor is set, even when it fails to resolve).
  # ---------------------------------------------------------------------------

  defp anchor_id(%{custom: custom}) when is_map(custom) do
    case Map.get(custom, @anchor_field) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp anchor_id(_company), do: nil

  defp anchor_match(customer_id, %Config{} = config) do
    config.customer_resource
    |> Ash.Query.new()
    |> Ash.Query.filter(org_id == ^config.org_id and id == ^customer_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> case do
      nil -> {:error, :not_linked}
      customer -> {:ok, customer, :anchor}
    end
  rescue
    _ -> {:error, :not_linked}
  end

  # ---------------------------------------------------------------------------
  # Mechanism 2 — the fail-closed domain-match fallback (anchor unset ONLY).
  # ---------------------------------------------------------------------------

  defp domain_match(%{domain: domain}, %Config{} = config) when is_binary(domain) and domain != "" do
    norm = Samen.Mailbox.Match.normalize(domain)

    matches =
      config.customer_resource
      |> Ash.Query.new()
      |> Ash.Query.ensure_selected([:billing_email])
      |> Ash.Query.filter(org_id == ^config.org_id)
      |> Ash.Query.limit(config.max_match_candidates)
      |> Ash.read!(authorize?: false)
      |> PiiResolution.resolve(config.customer_resource, %{plane: :tenant}, repo: config.repo)
      |> Enum.filter(fn candidate -> customer_domain(candidate) == norm end)

    # FAIL-CLOSED: exactly one confident candidate resolves; zero OR two-or-more
    # (ambiguous — never guessed) both resolve to honest absence.
    case matches do
      [one] -> {:ok, one, :domain}
      _ -> {:error, :not_linked}
    end
  rescue
    _ -> {:error, :not_linked}
  end

  defp domain_match(_company, _config), do: {:error, :not_linked}

  # A `%Samen.Masked{}` (an actor/plane that may not resolve this PII) yields NO domain
  # — it can never match. Never unwrapped.
  defp customer_domain(%{billing_email: email}) when is_binary(email), do: Samen.Mailbox.Match.domain(email)
  defp customer_domain(_masked_or_missing), do: nil
end
