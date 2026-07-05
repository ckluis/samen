import Config

config :s05_vault, ecto_repos: [Samen.Repo]

# Default KMS adapter is FileBacked — the external-store simulator the
# load-bearing red-path tests run against (ADR-001 §8.1).
config :s05_vault, kms_adapter: Samen.Kms.FileBacked

import_config "#{config_env()}.exs"
