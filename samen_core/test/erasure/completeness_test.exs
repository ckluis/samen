defmodule Samen.Erasure.CompletenessTest do
  @moduledoc """
  ADR-046 §6 — the erasure-completeness CAPSTONE gate (`Samen.Erasure.Completeness` +
  `mix samen.verify.erasure_completeness`).

  `Samen.Erasure.shred/2` is a KEY-destruction job — a value living OUTSIDE the
  per-subject-DEK envelope is not reached by key destruction, so it needs an explicit
  erasure arm or a shredded subject's data survives. This gate DISCOVERS every such
  residue from the LIVE schema (never `schema.dict`, which grandfathers) and ASSERTS a
  registered subject_id-keyed arm reaches each.

  Proven here, with anti-tautology positive controls:

    * DISCOVERY is real + non-vacuous — the fixture residue set contains ≥ the two hard
      classes (a `_bidx` derived-linkable column AND a `storage_key` column), and PHYSICAL
      (abbrev-prefixed) columns are resolved, not logical names.
    * PASSES on the fully-registered tree — every residue reached by a derived spec.
    * FAILS per-class when an arm is removed — drop the bidx spec → the email_bidx residue
      is named UNREACHED (positive control: with the spec it passes); drop the file spec →
      the storage_key residue is named UNREACHED.
    * FAILS on an UNREGISTERED `_bidx` column — the structural backstop catches a future
      blind index not in `Samen.DerivedLinkable`.
    * FAILS CLOSED on empty discovery — an empty derived-linkable OR storage_key set is a
      broken verifier, never a pass.
    * ACTIVATION — `default_specs/1` derives the correct subject-keyed arms from the live
      schema, and `install_default_specs/1` registers them so the arms actually fire.
  """
  use ExUnit.Case, async: false

  alias Samen.Erasure
  alias Samen.Erasure.Completeness

  alias SamenCore.Support.Completeness.{
    Credential,
    AuthToken,
    File,
    OrgAsset,
    Bag,
    RogueBidx
  }

  # The clean, fully-coverable residue population (no unregistered rogue column).
  @clean [Credential, AuthToken, File, OrgAsset, Bag]

  defp derived_specs, do: Erasure.default_specs(resources: @clean)

  defp check(resources, extra \\ []) do
    specs = derived_specs()

    Completeness.check(
      Keyword.merge(
        [
          resources: resources,
          bidx_specs: specs.blind_index_erasure_specs,
          file_specs: specs.file_erasure_specs,
          skip_bag_guard?: true
        ],
        extra
      )
    )
  end

  # ======================================================================
  # DISCOVERY — real, non-vacuous, PHYSICAL columns
  # ======================================================================

  test "discovery finds the real residue set from the live schema (physical columns)" do
    residues = Completeness.discover(resources: @clean)

    # Derived-linkable: BOTH bidx columns, discovered by their PHYSICAL (prefixed) source.
    dl_cols = residues.derived_linkable |> Enum.map(& &1.column) |> Enum.sort()
    assert dl_cols == ["atc_sent_to_bidx", "cpc_email_bidx"]

    # Each registered column resolves its owning-principal PHYSICAL subject column.
    cred = Enum.find(residues.derived_linkable, &(&1.column == "cpc_email_bidx"))
    assert cred.registered?
    assert cred.subject_column == "cpc_id"

    tok = Enum.find(residues.derived_linkable, &(&1.column == "atc_sent_to_bidx"))
    assert tok.registered?
    assert tok.subject_column == "atc_credential_id"

    # storage_key: both columns; File subject-linked, OrgAsset not.
    sk_cols = residues.storage_key |> Enum.map(& &1.column) |> Enum.sort()
    assert sk_cols == ["fil_storage_key", "med_storage_key"]

    file = Enum.find(residues.storage_key, &(&1.resource == File))
    assert file.subject_field == :uploaded_by_id
    assert Enum.find(residues.storage_key, &(&1.resource == OrgAsset)).subject_field == nil

    # custom bag discovered.
    assert Enum.any?(residues.custom_bag, &(&1.column == "bag_custom"))
  end

  # ======================================================================
  # PASSES on the fully-registered tree
  # ======================================================================

  test "check passes when every discovered residue is reached by a derived arm" do
    assert {:ok, report} = check(@clean)

    assert report.derived_linkable.count == 2
    assert report.storage_key.count == 2
    # OrgAsset is reported as an org-lifecycle residual, never a violation.
    assert report.org_asset_residuals != []
    assert Enum.any?(report.org_asset_residuals, &(&1 =~ "OrgAsset"))
  end

  test "check exercises the LIVE custom-bag define-time erasability guard (no repo needed)" do
    # skip_bag_guard? false → the real probe: a pii_declared field on an un-covered table
    # MUST be refused by Samen.CustomFields.define_field/2 (the guard runs before any DB
    # insert). Proves the erasure-by-construction mechanism is live.
    assert {:ok, report} = check(@clean, skip_bag_guard?: false)
    assert report.custom_bag.erasure_guard == true
    assert report.custom_bag.masking_arm == true
  end

  # ======================================================================
  # FAILS per-class when an arm is removed (+ positive controls)
  # ======================================================================

  test "removing the blind-index arm makes the email_bidx residue UNREACHED (refutable)" do
    # Positive control: WITH the derived bidx specs, it passes.
    assert {:ok, _} = check(@clean)

    # Drop the blind-index arm → the derived-linkable residues are named unreached.
    assert {:error, {:incomplete, violations, _}} = check(@clean, bidx_specs: [])
    assert Enum.any?(violations, &(&1 =~ "UNREACHED derived-linkable" and &1 =~ "cpc_email_bidx"))
    assert Enum.any?(violations, &(&1 =~ "atc_sent_to_bidx"))
  end

  test "removing the file arm makes the storage_key residue UNREACHED (refutable)" do
    # Positive control: WITH the derived file specs, it passes.
    assert {:ok, _} = check(@clean)

    assert {:error, {:incomplete, violations, _}} = check(@clean, file_specs: [])
    assert Enum.any?(violations, &(&1 =~ "UNREACHED storage_key blob" and &1 =~ "fil_storage_key"))
    # OrgAsset (no subject field) is NEVER a violation — only the subject-linked File is.
    refute Enum.any?(violations, &(&1 =~ "med_storage_key"))
  end

  test "an UNREGISTERED _bidx column fails the gate (structural backstop)" do
    # Include the rogue resource; its handle_bidx is not in Samen.DerivedLinkable.
    assert {:error, {:incomplete, violations, _}} = check([RogueBidx | @clean])

    assert Enum.any?(
             violations,
             &(&1 =~ "UNREGISTERED derived-linkable" and &1 =~ "rog_handle_bidx")
           )
  end

  # ======================================================================
  # FAILS CLOSED on empty discovery (non-vacuity floor)
  # ======================================================================

  test "empty derived-linkable discovery fails closed" do
    # Only a storage_key + bag resource, no _bidx column.
    assert {:error, {:no_residues_discovered, :derived_linkable}} =
             check([File, Bag])
  end

  test "empty storage_key discovery fails closed" do
    # Only a bidx resource, no storage_key column.
    assert {:error, {:no_residues_discovered, :storage_key}} = check([Credential])
  end

  # ======================================================================
  # ACTIVATION — derivation + install register the real subject-keyed arms
  # ======================================================================

  test "default_specs/1 derives the correct subject-keyed arms from the live schema" do
    specs = derived_specs()

    # One blind-index arm per REGISTERED derived-linkable column, physical columns +
    # resolved physical subject columns. Rogue/unregistered columns are NOT derived.
    bidx = Enum.sort_by(specs.blind_index_erasure_specs, & &1.bidx_column)

    assert [
             %{table_name: "atc_auth_token", bidx_column: "atc_sent_to_bidx", subject_column: "atc_credential_id"},
             %{table_name: "cpc_credential", bidx_column: "cpc_email_bidx", subject_column: "cpc_id"}
           ] = Enum.map(bidx, &Map.take(&1, [:table_name, :bidx_column, :subject_column]))

    # One file arm for the subject-linked File; the OrgAsset blob gets NO subject-keyed spec.
    assert [%{file_module: File, subject_field: :uploaded_by_id}] = specs.file_erasure_specs
  end

  test "install_default_specs/1 registers the arms into config so they actually fire" do
    prev_bidx = Application.fetch_env(:samen_core, :blind_index_erasure_specs)
    prev_file = Application.fetch_env(:samen_core, :file_erasure_specs)

    # Restore EXACTLY — including DELETING a key that was previously UNSET. Putting `nil`
    # back would poison `Application.get_env(_, _, [])` (it returns nil, not the []
    # default, for a key explicitly set to nil), crashing the arms' `Enum.map` for later
    # tests that run Erasure.shred.
    restore = fn key, prev ->
      case prev do
        {:ok, val} -> Application.put_env(:samen_core, key, val)
        :error -> Application.delete_env(:samen_core, key)
      end
    end

    on_exit(fn ->
      restore.(:blind_index_erasure_specs, prev_bidx)
      restore.(:file_erasure_specs, prev_file)
    end)

    installed = Erasure.install_default_specs(resources: @clean)

    assert Application.get_env(:samen_core, :blind_index_erasure_specs) ==
             installed.blind_index_erasure_specs

    assert Application.get_env(:samen_core, :file_erasure_specs) == installed.file_erasure_specs
    assert length(installed.blind_index_erasure_specs) == 2
    assert length(installed.file_erasure_specs) == 1
  end
end
