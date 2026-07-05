defmodule Demo.CrmVaultTest do
  @moduledoc """
  Demo dogfood vault round-trip test (T1.9).

  Exercises the full vault stack on real Demo.Crm resources:
    - write contact with composite PII (FullName + Emails) + scalar pii_ (dob)
    - verify domain columns hold vt_* tokens, NOT plaintext
    - verify Ash.read returns %Masked{} for all pii fields
    - verify reveal round-trip (Vault.store_field / Vault.reveal)
    - verify shred: post-shred reveals return :shredded
    - verify non_pii! registration and redaction
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Demo.Crm.Contact
  alias Demo.Repo
  alias Samen.Masked
  alias Samen.Vault
  alias Samen.Erasure
  alias Samen.NonPii

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp create_contact(overrides \\ %{}) do
    base = %{
      org_id: Ash.UUID.generate(),
      display_name: "Test Contact",
      full_name: %{first: "Alice", last: "Wonderland"},
      emails: %{primary: "alice@example.com"}
    }

    Contact
    |> Ash.Changeset.for_create(:create, Map.merge(base, overrides))
    |> Ash.create!()
  end

  # =========================================================================
  # Vault round-trip via Ash actions
  # =========================================================================

  describe "create via Ash :create action" do
    test "domain columns hold vt_* tokens, NOT plaintext" do
      c = create_contact()

      %{rows: [[full_name_col, emails_col]]} =
        Repo.query!(
          "SELECT cnt_full_name, cnt_emails FROM cnt_contact WHERE cnt_id = $1",
          [Ecto.UUID.dump!(c.id)]
        )

      for col <- [full_name_col, emails_col] do
        assert is_binary(col)
        assert String.starts_with?(col, "vt_"), "expected vault token, got #{inspect(col)}"
      end

      refute full_name_col =~ "Alice"
      refute full_name_col =~ "Wonderland"
      refute emails_col =~ "alice@example.com"
    end

    test "Ash.read returns %Masked{} for all pii fields" do
      c = create_contact()

      [read_back] =
        Contact
        |> Ash.Query.filter(id == ^c.id)
        |> Ash.Query.ensure_selected([:full_name, :emails])
        |> Ash.read!()

      assert %Masked{} = read_back.full_name
      assert %Masked{} = read_back.emails

      # Masked renders •••• everywhere
      assert to_string(read_back.emails) == "••••"
      assert to_string(read_back.full_name) == "••••"
      assert Jason.encode!(read_back.emails) == "\"••••\""
    end

    test "pii_vault has ciphertext rows for the contact" do
      c = create_contact()

      %{rows: rows} =
        Repo.query!(
          "SELECT field_name, ciphertext FROM pii_vault WHERE subject_id = $1",
          [c.id]
        )

      field_names = rows |> Enum.map(fn [fn_, _] -> fn_ end) |> Enum.sort()
      assert Enum.member?(field_names, "full_name")
      assert Enum.member?(field_names, "emails")

      for [_fn, ct] <- rows do
        assert is_binary(ct) and byte_size(ct) > 0
        refute ct =~ "Alice"
        refute ct =~ "alice@example.com"
      end
    end
  end

  # =========================================================================
  # Scalar pii_ field (dob)
  # =========================================================================

  describe "scalar pii_ field (dob)" do
    test "dob stored as token in pii_cnt_dob column" do
      c =
        Contact
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          display_name: "Dob Test",
          full_name: %{first: "Bob", last: "Builder"},
          dob: ~D[1990-01-15]
        })
        |> Ash.create!()

      %{rows: [[dob_col]]} =
        Repo.query!(
          "SELECT pii_cnt_dob FROM cnt_contact WHERE cnt_id = $1",
          [Ecto.UUID.dump!(c.id)]
        )

      assert is_binary(dob_col)
      assert String.starts_with?(dob_col, "vt_")
      refute dob_col =~ "1990"
      refute dob_col =~ "01-15"
    end

    test "dob read back as %Masked{}" do
      c =
        Contact
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          display_name: "Dob Read",
          full_name: %{first: "Carol", last: "Crypto"},
          dob: ~D[1985-06-20]
        })
        |> Ash.create!()

      [read_back] =
        Contact
        |> Ash.Query.filter(id == ^c.id)
        |> Ash.Query.ensure_selected([:dob])
        |> Ash.read!()

      assert %Masked{} = read_back.dob
      assert to_string(read_back.dob) == "••••"
    end
  end

  # =========================================================================
  # Vault direct reveal round-trip
  # =========================================================================

  describe "vault reveal round-trip" do
    test "store_field + reveal returns plaintext" do
      subject_id = Ash.UUID.generate()

      {:ok, token} =
        Vault.store_field(subject_id, :pii_email, :emails, "direct@example.com", Repo)

      masked = Masked.new(token, :emails)
      assert {:ok, "direct@example.com"} = Vault.reveal(masked, Repo)
    end

    test "masked value never contains plaintext" do
      subject_id = Ash.UUID.generate()
      {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, "secret@test.com", Repo)
      masked = Masked.new(token, :emails)

      refute to_string(masked) =~ "secret"
      refute inspect(masked) =~ "secret"
      refute Jason.encode!(masked) =~ "secret"
    end
  end

  # =========================================================================
  # Crypto-shred flow (T1.9: shred flow)
  # =========================================================================

  describe "crypto-shred flow" do
    test "shred destroys key; post-shred reveal returns :shredded" do
      subject_id = Ash.UUID.generate()

      {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, "shred@me.com", Repo)

      # Confirm reveal works before shred.
      assert {:ok, "shred@me.com"} = Vault.reveal(Masked.new(token, :emails), Repo)

      # Shred the subject.
      assert {:ok, _report} =
               Erasure.shred(subject_id,
                 repo: Repo,
                 actor_id: "test_shred_actor"
               )

      # Post-shred reveal must return :shredded.
      assert {:error, :shredded} = Vault.reveal(Masked.new(token, :emails), Repo)
    end

    test "shred seals vault rows with SHREDDED sentinel" do
      subject_id = Ash.UUID.generate()
      {:ok, _token} = Vault.store_field(subject_id, :pii_name, :full_name, "Shred Me", Repo)

      {:ok, _} = Erasure.shred(subject_id, repo: Repo, actor_id: "actor")

      %{rows: rows} =
        Repo.query!(
          "SELECT state FROM pii_vault WHERE subject_id = $1",
          [subject_id]
        )

      assert Enum.all?(rows, fn [state] -> state == "shredded" end)
    end
  end

  # =========================================================================
  # non_pii! registration and redaction (T1.9: one non_pii! reviewed column)
  # =========================================================================

  describe "non_pii! column (cnt_notes)" do
    setup do
      # Register cnt_notes as non_pii! (distinct-party reviewers).
      # subject_column is cnt_subject_id (:text) not cnt_id (:uuid) because the
      # non_pii! erasure arm passes string subject IDs via raw SQL params.
      NonPii.register(%{
        table_name: "cnt_contact",
        column_name: "cnt_notes",
        cleared_by: "alice@acme.com",
        reviewed_by: "bob@acme.com",
        reason: "Operational notes cleared in security review 2026-07",
        subject_column: "cnt_subject_id",
        redaction: "[REDACTED]",
        repo: Repo
      })

      :ok
    end

    test "non_pii! column is registered" do
      entries = NonPii.entries(repo: Repo)
      assert Enum.any?(entries, &(&1.table_name == "cnt_contact" and &1.column_name == "cnt_notes"))
    end

    test "shred redacts non_pii! column for the subject" do
      c =
        Contact
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          display_name: "Notes Contact"
        })
        |> Ash.create!()

      # Write a plaintext note and populate the string subject_id column.
      Repo.query!(
        "UPDATE cnt_contact SET cnt_notes = $1, cnt_subject_id = $2 WHERE cnt_id = $3",
        ["Call about contract renewal", c.id, Ecto.UUID.dump!(c.id)]
      )

      # Shred with c.id as the subject_id (the erasure arm matches cnt_subject_id = c.id).
      {:ok, _} =
        Erasure.shred(c.id,
          repo: Repo,
          actor_id: "test_actor"
        )

      %{rows: [[notes]]} =
        Repo.query!(
          "SELECT cnt_notes FROM cnt_contact WHERE cnt_id = $1",
          [Ecto.UUID.dump!(c.id)]
        )

      assert notes == "[REDACTED]"
    end
  end
end
