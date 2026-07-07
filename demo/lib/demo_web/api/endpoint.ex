defmodule DemoWeb.Api.Endpoint do
  @moduledoc """
  The mounted public API entry point (T3.11). This is the plug pipeline a host's
  Phoenix/Plug router forwards `/api/v1` to:

      forward "/api/v1", DemoWeb.Api.Endpoint

  Pipeline order:

    1. `DemoWeb.Api.KeyAuthPlug` — resolve the `Authorization: Bearer <key>` into a
       `%Samen.Scope{}` actor (the two key classes), or set no actor (fail closed).
    2. `DemoWeb.Api.Router`      — the generated AshJsonApi router over the SAME Ash
       resources. It runs the resources' own policy stack (org-scope + RBAC) and the
       `Samen.Api.PiiResolution` read preparation (the two-plane PII rule).

  The operator-plane masking (vaulted field absent without a grant) is enforced at
  the RECORD level by `Samen.Api.PiiResolution` (it sets forbidden fields to
  `%Ash.ForbiddenField{}`, which the serializer omits) — not by a response rewrite.
  So there is no post-serialization body munging: the field is gone before the JSON
  is ever built. This keeps "absent by omission" a structural property.
  """
  use Plug.Builder

  plug(DemoWeb.Api.KeyAuthPlug)
  plug(DemoWeb.Api.Router)
end
