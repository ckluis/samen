defmodule Demo.WebhookAllowlist.Domain do
  @moduledoc """
  Test-support domain for the F3.6 webhook opt-in allowlist red paths.

  Holds `Demo.WebhookAllowlist.Widget` — a resource that carries a Tier-1 `:custom`
  jsonb bag AND a `json_api do show_fields([…]) end` allowlist that DELIBERATELY does
  NOT include `:custom` (nor `org_id`/`inserted_at`/`updated_at`). It exists so the
  webhook payload serializer can be exercised end-to-end against a real Ash resource
  whose `show_fields` omits the `custom` bag — proving the bag is ABSENT from the
  outbound payload even when populated.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Demo.WebhookAllowlist.Widget)
  end
end

defmodule Demo.WebhookAllowlist.Widget do
  @moduledoc """
  F3.6 fixture — a resource with a Tier-1 `:custom` bag and an opt-in `show_fields`
  allowlist that OMITS the bag.

  `show_fields([:id, :display_name])` is the opt-in allowlist. Fields present on the
  resource but ABSENT from that list — `:custom` (the Tier-1 jsonb bag),
  `:internal_label`, plus the injected `org_id`/`inserted_at`/`updated_at` — must be
  ABSENT from the webhook payload by omission.

  The payload serializer reads attributes + `show_fields` off the resource module and
  reads values off the in-memory record struct, so the red-path tests build payloads
  from structs WITHOUT a DB round-trip (no migration needed for this fixture).
  """
  use Samen.Resource,
    otp_app: :demo,
    domain: Demo.WebhookAllowlist.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    abbrev: "waw"

  postgres do
    table("waw_widget")
    repo(Demo.Repo)
  end

  json_api do
    type("webhook_allowlist_widget")
    # OPT-IN allowlist — deliberately omits :custom, :internal_label, org_id,
    # inserted_at, updated_at.
    show_fields([:id, :display_name])
  end

  attributes do
    attribute(:display_name, :string, public?: true, allow_nil?: false)
    # A public, non-PII field that is NOT on the allowlist → must be ABSENT.
    attribute(:internal_label, :string, public?: true)
    # Tier-1 custom bag — opt-in. Public but NOT on show_fields → must be ABSENT
    # even when populated.
    attribute(:custom, :map, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
