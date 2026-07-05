# Fresh KMS key store per run — external to Postgres, external to the repo.
key_dir = Application.get_env(:s05_vault, :kms_key_dir)
if key_dir, do: File.rm_rf!(key_dir)

# Build the database and run migrations against real Postgres (no sandbox).
S05Vault.DBCase.reset_db!()

ExUnit.start()
