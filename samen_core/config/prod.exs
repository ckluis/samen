import Config
# samen_core is a library; a host app supplies its own prod repo config. This
# file exists so `MIX_ENV=prod mix compile` resolves config_env/0.

# ADR-052 §2.1 (`no_plaintext_pii` tier `:logger`): a prod build logs at :info or above, so
# `:debug` call sites never reach a production log.
config :logger, level: :info
