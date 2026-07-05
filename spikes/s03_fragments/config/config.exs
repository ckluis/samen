import Config

config :s03_fragments,
  ecto_repos: [S03Fragments.Repo],
  ash_domains: [S03Fragments.Clinical]

config :ash,
  disable_async?: true

# AshPostgres migration primary key shape (matches s02 spike convention).
config :s03_fragments, S03Fragments.Repo, migration_primary_key: [name: :id, type: :binary_id]

import_config "#{config_env()}.exs"
