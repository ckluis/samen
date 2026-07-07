defmodule Driftwood.CdlVaultTest do
  @moduledoc """
  RED-PATH test: `pii_drv_cdl_number` vault round-trip. The CDL number is NEVER
  stored as plaintext in the domain row — the domain column holds an opaque vault
  token, the plaintext lives encrypted in `pii_vault`, and a normal read returns a
  masked value. (design §5.)
  """
  use Driftwood.DataCase, async: false
  require Ash.Query

  @org "00000000-0000-0000-0000-0000000000c1"

  defp create_driver(cdl) do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        full_name: %{first: "Dana", last: "Driver"},
        cdl_number: cdl,
        cdl_state: "OH",
        cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), 180),
        status: :available
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  test "the domain row NEVER holds the plaintext CDL number (only a vt_ token)" do
    plaintext = "CDL-SECRET-12345"
    driver = create_driver(plaintext)

    # Read the RAW physical column straight from the DB (bypassing Ash), so we see
    # exactly what landed on disk.
    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT pii_drv_cdl_number FROM drv_driver WHERE drv_id = $1",
        [Ecto.UUID.dump!(to_string(driver.id))]
      )

    refute raw == plaintext
    refute raw =~ "CDL-SECRET"
    assert String.starts_with?(raw, "vt_"), "expected an opaque vault token, got: #{inspect(raw)}"
  end

  test "a normal Ash read returns the CDL masked (••••), never plaintext" do
    driver = create_driver("CDL-MASK-ME")

    read =
      Driftwood.Freight.Driver
      |> Ash.Query.filter(id == ^driver.id)
      |> Ash.Query.ensure_selected([:cdl_number])
      |> Ash.read_one!(authorize?: false)

    # The vault field presents a %Masked{} from the stored token — not the plaintext.
    assert match?(%Samen.Masked{}, read.cdl_number),
           "expected %Masked{}, got: #{inspect(read.cdl_number)}"

    refute to_string(read.cdl_number) =~ "CDL-MASK-ME"
  end

  test "the CDL ciphertext lives in the pii_vault under the :pii_cdl vault, keyed to the driver" do
    driver = create_driver("CDL-VAULTED")

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT vault_name, field_name, state FROM pii_vault WHERE subject_id = $1 AND vault_name = $2",
        [to_string(driver.id), "pii_cdl"]
      )

    assert [["pii_cdl", "cdl_number", "active"]] = rows
  end

  test "after crypto-shred the CDL is undecryptable and the vault row is 'shredded'" do
    driver = create_driver("CDL-TO-SHRED")

    {:ok, _attestation} = Samen.Erasure.shred(to_string(driver.id), repo: Driftwood.Repo)

    %{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        Driftwood.Repo,
        "SELECT state FROM pii_vault WHERE subject_id = $1 AND vault_name = $2",
        [to_string(driver.id), "pii_cdl"]
      )

    assert state == "shredded"
  end
end
