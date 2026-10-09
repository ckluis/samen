import Config

# demo — production COMPILE-TIME posture. `config/config.exs` ends with
# `import_config "#{config_env()}.exs"`, so a `MIX_ENV=prod` config load imports THIS file.
# demo is a dogfood host (no release ships), but its prod posture is still asserted: the
# `no_plaintext_pii` tier `:logger` (ADR-052 §2.1) reads it and fails a level below :info.
config :logger, level: :info
