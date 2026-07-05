import Config

config :s02_transformer,
  ecto_repos: [S02Transformer.Repo],
  ash_domains: [S02Transformer.Crm]

config :ash,
  disable_async?: true

# Where AshPostgres writes generated migrations/snapshots for the round-trip test.
config :s02_transformer, S02Transformer.Repo, migration_primary_key: [name: :id, type: :binary_id]

import_config "#{config_env()}.exs"
