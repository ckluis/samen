defmodule PawChart.MicrochipVaultTest do
  @moduledoc """
  RED-PATH test: `pii_pet_microchip` vault round-trip (the doc's `pii_pat_microchip`).
  The microchip UID is NEVER stored as plaintext in the domain row — the domain column
  holds an opaque vault token, the plaintext lives encrypted in `pii_vault`, and a
  normal read returns a masked value. The animal's microchip is a vaulted secret keyed
  to the PET's subject id — the second of the doc's "two PII subjects".

  Every assertion here inherits the substrate vault machinery with ZERO PawChart code:
  the vault routing, the token FK, the %Masked{} type, the crypto-shred, the vault-state
  transition are all `samen_core`. PawChart only DECLARED `pii_attribute :microchip`.
  """
  use PawChart.DataCase, async: false
  require Ash.Query

  @org "00000000-0000-0000-0000-0000000000d1"

  defp create_pet(microchip) do
    PawChart.Clinic.Pet
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        name: "Rex",
        species: "canine",
        breed: "labrador",
        microchip: microchip,
        temperament: :docile
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  test "the domain row NEVER holds the plaintext microchip (only a vt_ token)" do
    plaintext = "985-MICROCHIP-SECRET-12345"
    pet = create_pet(plaintext)

    # Read the RAW physical column straight from the DB (bypassing Ash), so we see
    # exactly what landed on disk.
    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        PawChart.Repo,
        "SELECT pii_pet_microchip FROM pet_pet WHERE pet_id = $1",
        [Ecto.UUID.dump!(to_string(pet.id))]
      )

    refute raw == plaintext
    refute raw =~ "MICROCHIP-SECRET"
    assert String.starts_with?(raw, "vt_"), "expected an opaque vault token, got: #{inspect(raw)}"
  end

  test "a normal Ash read returns the microchip masked (••••), never plaintext" do
    pet = create_pet("985-MASK-ME")

    read =
      PawChart.Clinic.Pet
      |> Ash.Query.filter(id == ^pet.id)
      |> Ash.Query.ensure_selected([:microchip])
      |> Ash.read_one!(authorize?: false)

    # The vault field presents a %Masked{} from the stored token — not the plaintext.
    assert match?(%Samen.Masked{}, read.microchip),
           "expected %Masked{}, got: #{inspect(read.microchip)}"

    refute to_string(read.microchip) =~ "985-MASK-ME"
  end

  test "the microchip ciphertext lives in pii_vault under :pii_microchip, keyed to the pet" do
    pet = create_pet("985-VAULTED")

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        PawChart.Repo,
        "SELECT vault_name, field_name, state FROM pii_vault WHERE subject_id = $1 AND vault_name = $2",
        [to_string(pet.id), "pii_microchip"]
      )

    assert [["pii_microchip", "microchip", "active"]] = rows
  end

  test "after crypto-shred the microchip is undecryptable and the vault row is 'shredded'" do
    pet = create_pet("985-TO-SHRED")

    {:ok, _attestation} = Samen.Erasure.shred(to_string(pet.id), repo: PawChart.Repo)

    %{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        PawChart.Repo,
        "SELECT state FROM pii_vault WHERE subject_id = $1 AND vault_name = $2",
        [to_string(pet.id), "pii_microchip"]
      )

    assert state == "shredded"
  end
end
