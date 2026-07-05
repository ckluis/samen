defmodule Samen.Vault.Person do
  @moduledoc """
  A domain row that carries an FK **vault token**, never plaintext (doc D3).

  `pii_email_token` references `Samen.Vault.PiiEmail.token`. `subject_id` is the
  crypto-shred unit. The default read materializes `email` as `%Masked{}`
  (see `Samen.Vault.load_person/1`) — plaintext is available ONLY through
  `Samen.Vault.reveal/2`.

  We deliberately model this with an Ecto changeset round-trip so the plan's
  acceptance ("masked value survives changeset round-trip") is proven against
  real casting/validation machinery.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "person" do
    field :subject_id, :string
    field :display_name, :string
    field :pii_email_token, :string
    # Virtual: the materialized field value. Its normal value is %Masked{}.
    field :email, :map, virtual: true
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for a domain row. Note it never accepts plaintext email — only the
  token FK. Plaintext goes to the vault via `Samen.Vault.store_email/3`.
  """
  def changeset(person, attrs) do
    person
    |> cast(attrs, [:subject_id, :display_name, :pii_email_token])
    |> validate_required([:subject_id, :pii_email_token])
  end
end
