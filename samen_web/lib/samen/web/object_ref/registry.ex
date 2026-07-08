defmodule Samen.Web.ObjectRef.Registry do
  @moduledoc """
  The card OVERRIDE registry (ADR-012 §4.4) — a thin `resource-key -> card module` seam over
  the catalog-driven `DefaultCard`. A resource with no override renders the default card, so a
  NEW vertical inherits unfurl for every catalogued resource with ZERO cards written; a
  resource that deserves a bespoke layout registers a card module.

  ## Two sources of overrides (both DATA, no framework edit)

    1. **Framework first-class cards** — a small built-in set for the inherited scopes
       (`crm.person`, `crm.company`, `support.ticket`, `billing.invoice`). These ship with the
       framework and cover the 80% verticals.
    2. **Host overrides** — a `:object_cards` label on the mount (`%{"freight.driver" => Mod}`),
       the SAME host-supplies-data pattern as `aggregate_loader:` (ADR-009). A vertical registers
       its own cards without touching the framework. Host overrides WIN over the framework set
       (a host can specialize an inherited key).

  ## The registry NEVER changes masking

  An override card receives the ALREADY-RESOLVED record and only chooses LAYOUT — every value
  it renders is the resolver's already-resolved value (a `%Masked{}` stays `%Masked{}`). A card
  module implements `card/3 :: (key, resource, resolved_record) -> %Card{}`. If it raises, we
  fall back to the default card (fail-safe — an override bug never breaks unfurl).
  """

  alias Samen.Web.Mount
  alias Samen.Web.ObjectRef.{DefaultCard, Card}

  # The framework's first-class override cards for the inherited scopes.
  @framework_cards %{
    "crm.person" => Samen.Web.ObjectRef.Cards.Person,
    "crm.company" => Samen.Web.ObjectRef.Cards.Company,
    "support.ticket" => Samen.Web.ObjectRef.Cards.Ticket,
    "billing.invoice" => Samen.Web.ObjectRef.Cards.Invoice
  }

  @doc """
  Build the card for a resolved record: a host/framework override if one is registered for
  `key`, else the catalog-driven default. Fail-safe to the default card on any override error.
  """
  @spec card_for(Mount.t(), String.t(), module(), struct()) :: Card.t()
  def card_for(%Mount{} = mount, key, resource, record) do
    case card_module(mount, key) do
      nil ->
        DefaultCard.card(key, resource, record)

      module ->
        module.card(key, resource, record)
    end
  rescue
    _ -> DefaultCard.card(key, resource, record)
  end

  @doc "The card module registered for `key` on this mount, or nil (→ default card)."
  @spec card_module(Mount.t(), String.t()) :: module() | nil
  def card_module(%Mount{} = mount, key) do
    host = host_cards(mount)
    Map.get(host, key) || Map.get(@framework_cards, key)
  end

  @doc "The framework's built-in override keys (for introspection / tests)."
  def framework_keys, do: Map.keys(@framework_cards)

  # A host registers overrides via the `:object_cards` mount label (data, not code).
  defp host_cards(%Mount{} = mount) do
    case Mount.label(mount, :object_cards, nil) do
      %{} = map -> map
      _ -> %{}
    end
  end
end
