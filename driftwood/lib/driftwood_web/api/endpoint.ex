defmodule DriftwoodWeb.Api.Endpoint do
  @moduledoc """
  F1 (Gate-5 carry) — the mounted public API entry point over the freight vertical. This
  is the plug pipeline the host router forwards `/api/v1` to:

      forward "/api/v1", DriftwoodWeb.Api.Endpoint

  Pipeline order:

    1. `DriftwoodWeb.Api.KeyAuthPlug` — resolve the `Authorization: Bearer <key>` into a
       plane-bearing actor (the two key classes), or set no actor (fail closed).
    2. `DriftwoodWeb.Api.Router`      — the generated AshJsonApi router over the SAME Ash
       resources. It runs the resources' own policy stack (OrgScope + RBAC) and the
       `Samen.Api.PiiResolution` read preparation (the two-plane PII rule).

  The operator-plane masking (vaulted CDL absent without a grant) is enforced at the
  RECORD level by `Samen.Api.PiiResolution` (it sets forbidden fields to
  `%Ash.ForbiddenField{}`, which the serializer omits) — not by a response rewrite. The
  field is gone before the JSON is ever built ("absent by omission" is structural).
  """
  use Plug.Builder

  plug(DriftwoodWeb.Api.KeyAuthPlug)
  plug(DriftwoodWeb.Api.Router)
end
