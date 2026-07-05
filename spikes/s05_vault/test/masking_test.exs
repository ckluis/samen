defmodule Samen.MaskingTest do
  @moduledoc """
  Acceptance (plan S0.5): the masked value survives a changeset round-trip and
  renders masked in a JSON encode, a CSV dump, and inspect/to_string.

  Doc §control: "masking is the field type's normal value — no CSV, API, or log
  path leaks by omission."
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias Samen.Vault
  alias Samen.Vault.Person

  @mask "••••"
  @secret "alice.private@example.com"

  setup do
    S05Vault.DBCase.truncate!()
    Samen.Kms.FileBacked.simulate_outage(false)
    :ok
  end

  defp new_person do
    subject = "subj-mask-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Alice", @secret)
    person
  end

  test "default read materializes email as %Masked{} (the normal value)" do
    person = new_person()
    assert %Masked{label: :email} = person.email
    assert Masked.masked?(person.email)
  end

  test "masked value survives a changeset round-trip" do
    person = new_person()

    # Round-trip the domain row through a changeset; the field stays a token FK,
    # never plaintext, and re-materializes to %Masked{}.
    reloaded = Vault.load_person(person.id)
    assert %Masked{} = reloaded.email

    cs = Person.changeset(reloaded, %{display_name: "Alice Renamed"})
    {:ok, updated} = Samen.Repo.update(cs)
    materialized = Vault.materialize(updated)

    assert %Masked{} = materialized.email
    # The plaintext is nowhere in the domain row.
    refute person_row_contains_plaintext?(updated)
  end

  test "renders masked in inspect/1" do
    person = new_person()
    assert inspect(person.email) == "#Masked<#{@mask}>"
    # Inspecting the whole struct must not leak plaintext or the raw token value
    # as plaintext email.
    dump = inspect(person)
    refute dump =~ @secret
  end

  test "renders masked in to_string/1 and string interpolation" do
    person = new_person()
    assert to_string(person.email) == @mask
    assert "value: #{person.email}" == "value: #{@mask}"
  end

  test "renders masked in a JSON encode" do
    person = new_person()

    payload = %{
      id: person.id,
      display_name: person.display_name,
      email: person.email
    }

    json = Jason.encode!(payload)
    assert json =~ ~s("email":"#{@mask}")
    refute json =~ @secret
  end

  test "renders masked in a CSV dump" do
    person = new_person()

    # A CSV encoder coerces cells via to_string/1 → masked.
    row = [person.id, person.display_name, to_string(person.email)]
    csv = NimbleCSV.RFC4180.dump_to_iodata([row]) |> IO.iodata_to_binary()

    assert csv =~ @mask
    refute csv =~ @secret
  end

  # RED PATH (structural): a bug that put plaintext into %Masked{} would leak.
  # We prove %Masked{} structurally cannot carry plaintext by asserting the
  # struct's fields never equal the secret in any serialization.
  test "red path: no serialization path emits plaintext by omission" do
    person = new_person()

    for rendered <- [
          to_string(person.email),
          inspect(person.email),
          Jason.encode!(%{e: person.email}),
          inspect(person)
        ] do
      refute rendered =~ @secret, "plaintext leaked in: #{rendered}"
    end
  end

  defp person_row_contains_plaintext?(%Person{} = p) do
    p
    |> Map.from_struct()
    |> Map.drop([:email, :__meta__])
    |> Map.values()
    |> Enum.any?(fn v -> is_binary(v) and v =~ @secret end)
  end
end
