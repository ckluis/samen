import Config

config :s04_catalog_tx,
  ecto_repos: [S04CatalogTx.Repo],
  ash_domains: [S04CatalogTx.Crm]

config :ash,
  disable_async?: true

config :s04_catalog_tx, S04CatalogTx.Repo, migration_primary_key: [name: :id, type: :binary_id]

import_config "#{config_env()}.exs"
