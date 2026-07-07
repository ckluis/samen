defmodule DemoWeb.Api.Router do
  @moduledoc """
  The public JSON:API router (T3.11; plan OD-6 — AshJsonApi ONLY).

  This is the generated AshJsonApi router over the SAME Ash resources the LiveView UI
  and the operator plane use — one write path, one policy stack, one catalog (doc
  §external-surface). It is URL-versioned: the top-level plug forwards `/api/v1` to
  this router (see `DemoWeb.Api.Endpoint`), so every route here lives under `/api/v1`.

  ## Governed both ways

  Inbound requests carry a `%Samen.Scope{}` actor set by `DemoWeb.Api.KeyAuthPlug`
  (the api_key → actor resolver), so the SAME Ash policies (org-scope + RBAC +
  reveal-grant) run for an API request as for a UI request. The router itself is a
  thin AshJsonApi plug; the authorization is the resources' own policy stack.

  ## Allowlist serialization

  Field exposure is opt-in per resource (`json_api do show_fields … end`). A field
  absent from a resource's allowlist is absent from every payload — including a
  newly added storage column (default not-exposed). See the resource `json_api`
  blocks (Demo.Crm.Contact, Demo.Identity.{Org,User,Membership}).
  """
  use AshJsonApi.Router,
    domains: [Demo.Crm, Demo.Identity],
    prefix: "/api/v1"
end
