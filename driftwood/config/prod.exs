import Config

# Driftwood — production COMPILE-TIME config (ADR-045 §2.1). `config/config.exs` ends with
# `import_config "#{config_env()}.exs"`, so a MIX_ENV=prod build (a release, or
# `Config.Reader.read!(env: :prod)`) imports THIS file. Without it a prod config load ABORTS on
# the missing `prod.exs`. SECRETS are read fail-closed at BOOT in a `config/runtime.exs` (ADR-024,
# the --deploy layer); this file carries only compile-time prod POSTURE.

# Quieter prod logging (dev is :info already; keep prod at :info).
config :logger, level: :info

# --- tenant-auth gate: ARMED IN PROD (ADR-045 §2, V-F1 Option A) ----------------------------
# Already set (and load-bearing) in `config/config.exs` via `auth_required?: config_env() ==
# :prod`, evaluated BEFORE this import — the gate is ARMED by the time this file loads. Re-stated
# so the prod posture is legible in one place and cannot silently drift to disarmed: a prod host
# that reaches boot DISARMED refuses to start (`Samen.Web.TenantGate.assert_prod_armed!/1`, wired
# in `driftwood/lib/driftwood/application.ex`).
config :driftwood, auth_required?: true

# --- KMS keystore posture (ADR-045 §4.2, O5) ------------------------------------------------
# Driftwood has no `--deploy` `runtime.exs`, so no `:kms_adapter` is selected here and the vault
# falls back to `Samen.Kms.FileBacked` — a REAL adapter (the boot guard
# `Samen.Kms.assert_prod_adapter_ready!/0` admits it), but NOT durable across an ephemeral release
# filesystem. Before running a real production deploy, wire a `config/runtime.exs` that selects a
# real KMS you operate (see the generated deploy runbook for the pattern).
