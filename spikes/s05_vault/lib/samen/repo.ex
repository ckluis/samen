defmodule Samen.Repo do
  @moduledoc """
  Ecto repo for the spike. Backs the vault ciphertext table and the domain
  table so the PITR/`pg_dump` red path runs against real on-disk Postgres data.
  """
  use Ecto.Repo, otp_app: :s05_vault, adapter: Ecto.Adapters.Postgres
end
