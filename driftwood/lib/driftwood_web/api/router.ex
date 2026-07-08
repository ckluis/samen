defmodule DriftwoodWeb.Api.Router do
  @moduledoc """
  F1 (Gate-5 carry) — the public JSON:API router over the freight vertical (doc
  §external-surface; OD-6 AshJsonApi only).

  This is the generated AshJsonApi router over the SAME Ash resources the LiveView UI +
  the operator plane use — one write path, one policy stack, one catalog. It is
  URL-versioned: the top-level plug forwards `/api/v1` to this router (see
  `DriftwoodWeb.Api.Endpoint`), so every route here lives under `/api/v1`
  (`/api/v1/drivers`, `/api/v1/drivers/:id`).

  ## Governed both ways

  Inbound requests carry a plane-bearing actor set by `DriftwoodWeb.Api.KeyAuthPlug`, so
  the SAME Ash policies (OrgScope + RBAC) run for an API request as for a UI request, and
  the SAME `Samen.Api.PiiResolution` egress rule applies (tenant → CDL in clear; operator
  → CDL absent without a grant).

  ## Allowlist serialization

  Field exposure is opt-in per resource (`json_api do show_fields … end`). A field absent
  from a resource's allowlist is absent from every payload — including a storage column
  (`pii_drv_cdl_number`, `drv_org_id`) which is never allowlisted (default not-exposed).
  """
  use AshJsonApi.Router,
    domains: [Driftwood.Freight],
    prefix: "/api/v1"
end
