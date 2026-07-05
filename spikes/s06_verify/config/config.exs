import Config

config :s06_verify,
  ecto_repos: [S06Verify.Repo],
  ash_domains: [S06Verify.Crm]

config :ash,
  disable_async?: true

config :s06_verify, S06Verify.Repo, migration_primary_key: [name: :id, type: :binary_id]

import_config "#{config_env()}.exs"
