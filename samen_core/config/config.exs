import Config

# samen_core is a library. The Repo and domains below exist only so the kernel's
# own test/dev fixtures (test/support/*) can be introspected by `mix ash.codegen`
# and exercised against a real Postgres. Host applications configure their own
# repo + domains.
config :samen_core,
  ecto_repos: [SamenCore.TestRepo],
  ash_domains: [
    SamenCore.Support.Crm,
    SamenCore.Support.Clinical,
    SamenCore.Support.PropDomain
  ]

config :ash, disable_async?: true

# AshPostgres migration primary key shape (matches the S0.2/S0.3 spike convention:
# binary_id named :id — the abbrev transformer then prefixes it per-resource).
config :samen_core, SamenCore.TestRepo,
  migration_primary_key: [name: :id, type: :binary_id]

import_config "#{config_env()}.exs"
