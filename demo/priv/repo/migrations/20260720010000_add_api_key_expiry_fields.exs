defmodule Demo.Repo.Migrations.AddApiKeyExpiryFields do
  @moduledoc """
  F3.4 (Trust & Lifecycle): bounded API-key expiry + last-use observability.

  Adds two columns to `key_api_key`:

    * `key_expires_at`   — the hard time ceiling on the key's life. The auth lookup
      filters `expires_at > now`, so an expired row is never resolved to an actor
      (deny-on-read). Minted keys are always bounded (`Samen.Scope.ApiKey.bounded_expiry/2`);
      `NULL` is a legacy pre-gate row (non-expiring predicate).
    * `key_last_used_at` — best-effort stamped by the auth path on a successful
      resolve (stale-key hygiene). Never gates auth.

  Both are plain bounded (timestamp) columns — no PII, no catalog PII fields — so
  this mirrors the `AddFeatureFlagEngineFields` add-column precedent (no catalog_sync).
  """
  use Ecto.Migration

  def up do
    alter table(:key_api_key) do
      add(:key_expires_at, :utc_datetime)
      add(:key_last_used_at, :utc_datetime)
    end
  end

  def down do
    alter table(:key_api_key) do
      remove(:key_expires_at)
      remove(:key_last_used_at)
    end
  end
end
