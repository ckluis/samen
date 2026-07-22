defmodule Samen.RedPathVaultScanTest do
  @moduledoc """
  ADR-036 T15 attempts 3-4 (two root-cause fixes to
  `Samen.RedPath.assert_vault_routed!/5`'s leak-detection scans):

  ## Attempt 3 — the whole-row scan's UUID-decimal-byte artifact

  A raw (non-Ecto-schema) `SELECT *` decodes a Postgres `uuid` column as a
  16-byte Elixir BINARY; `inspect/1` on that renders a comma-separated DECIMAL
  BYTE LIST (`<<98, 100, 39, ...>>`). A SHORT numeric `plaintexts` marker (the
  kind a tightly-bounded scalar type like `Samen.Type.Score`, capped 0-100 with
  no way to widen it, is stuck with) has a real, empirically-reproduced chance
  of coincidentally matching one of those random bytes — a FALSE "leak" on the
  `id`/`org_id` columns, which never held the secret at all
  (`gen_resource_type_menu_probe.exs` hit this live: `plaintext "100" found in
  the raw ... row`, traced to a random `org_id` byte). FIXED by
  `identity_column_names/1`: the whole-row scan excludes the primary key +
  every UUID-typed attribute.

  ## Attempt 4 — the per-field token check was LOOSE, not just flaky

  The vaulted field's OWN column check used to be a loose
  `String.starts_with?(value, "vt_")` PLUS a substring scan of that column for
  each `plaintexts` marker. Two problems, both fixed here:

    1. **A real (narrow) under-check.** The loose prefix accepted ANY string
       starting with `"vt_"` — a leaked plaintext shaped like
       `"vt_myemail@example.com"` would have PASSED it. Replaced with a
       STRICT structural assertion of the exact token shape
       (`~r/^vt_[0-9a-f]{32}$/`, matching `Samen.Vault.generate_token/0`
       exactly: `"vt_" <> 32 lowercase hex chars`) — this is a net
       STRENGTHENING, not merely a flake fix.
    2. **The same UUID-adjacent noise, one level down.** A `vt_*` token is a
       genuinely random 32-hex-char string; a short numeric marker (e.g.
       Score's "100") had a real, if smaller (~0.7%/record), chance of
       coincidentally matching a substring of it — in BOTH the per-field
       substring scan (now deleted, superseded by the structural assertion)
       AND the whole-row scan (now also excludes every checked field's
       storage column, since a NON-token value there is caught
       deterministically by the structural assertion instead).

  Net effect: a leak into the vaulted column fails the strict format assertion
  deterministically; a leak into any OTHER non-identity column still fails the
  whole-row substring scan; no plaintext substring check ever runs against
  random hex/UUID data anywhere in the function.

  ## The two-sided proof (house convention: a red path pairs denial with a
  positive control — a check that cannot fail is a bug)

    * GREEN — 50 fresh records (50 fresh random `id`/`org_id` UUID pairs +
      fresh `vt_*` tokens) with a 7-digit marker, PLUS 5 fresh records with the
      EXACT real-world marker `field_type_menu.ex` ships for `--field-type
      score` ("100") — both now fully immune (attempts 3+4 combined), never
      false-positive.
    * RED, whole-row — a MODELED leak in a NON-identity, still-scanned column
      (`label`), via a raw-SQL plant and a normal Ash write, still raises.
    * RED, token column (attempt-4, NEW) — a MODELED leak DIRECTLY IN the
      vaulted column: a bare plaintext, and a `"vt_" <> plaintext` value that
      would have PASSED the OLD loose prefix check but fails the strict
      format — both still raise, proving the structural assertion is not
      vacuous and the token-column exclusion from the whole-row scan does not
      create a blind spot.
  """
  use ExUnit.Case, async: false

  alias SamenCore.Support.RichTypes.PersonalFixture
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  defp create!(attrs) do
    PersonalFixture
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: Ash.UUID.generate()}, attrs))
    |> Ash.create!()
  end

  defp plant_email_column!(record, raw_value) do
    %Postgrex.Result{num_rows: 1} =
      TestRepo.query!("UPDATE srp_personal_fixture SET pii_srp_email = $1 WHERE srp_id = $2", [
        raw_value,
        Ecto.UUID.dump!(record.id)
      ])

    :ok
  end

  describe "no false positive (attempts 3+4 combined — the UUID-byte row artifact AND the token-hex noise)" do
    test "50 fresh records, a 7-digit marker never false-positives" do
      for _ <- 1..50 do
        record = create!(%{email: "person@example.test", label: "row"})

        assert :ok =
                 Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
                   "9182736"
                 ])
      end
    end

    test "5 fresh records, the EXACT real-world marker field_type_menu.ex ships for --field-type score (\"100\") never false-positives" do
      for _ <- 1..5 do
        record = create!(%{email: "person@example.test", label: "row"})

        # Pre-attempt-3: would false-positive whenever a random id/org_id byte
        # equaled 100. Pre-attempt-4: would ALSO risk false-positiving whenever
        # "100" coincidentally appeared inside the field's own random vt_ hex
        # token. Both sources are now eliminated.
        assert :ok =
                 Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
                   "100"
                 ])
      end
    end
  end

  describe "still catches a genuine leak in a NON-identity column (anti-tautology: attempt-3's exclusion is surgical)" do
    test "a plaintext planted in label via raw SQL IS still detected" do
      record = create!(%{email: "person@example.test", label: "clean"})

      leaked = "LEAKED-PLAINTEXT-#{System.unique_integer([:positive])}"

      %Postgrex.Result{num_rows: 1} =
        TestRepo.query!("UPDATE srp_personal_fixture SET srp_label = $1 WHERE srp_id = $2", [
          leaked,
          Ecto.UUID.dump!(record.id)
        ])

      assert_raise ExUnit.AssertionError, ~r/found in the raw srp_personal_fixture row/, fn ->
        Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
          leaked
        ])
      end
    end

    test "a plaintext naturally present in label (a normal Ash write) IS still detected" do
      record = create!(%{email: "person@example.test", label: "NATURAL-PLAINTEXT-MARK"})

      assert_raise ExUnit.AssertionError, ~r/found in the raw srp_personal_fixture row/, fn ->
        Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
          "NATURAL-PLAINTEXT-MARK"
        ])
      end
    end
  end

  describe "still catches a genuine leak IN the vaulted column (attempt-4: structural assertion isn't vacuous)" do
    @token_shape_msg ~r/expected srp_personal_fixture\.pii_srp_email to hold a vt_\[0-9a-f\]\{32\} token/

    test "a bare plaintext (not a vt_ token at all) IS still detected" do
      record = create!(%{email: "person@example.test", label: "row"})
      :ok = plant_email_column!(record, "not-a-token-at-all@example.test")

      assert_raise ExUnit.AssertionError, @token_shape_msg, fn ->
        Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
          "not-a-token-at-all@example.test"
        ])
      end
    end

    test "a leak disguised with the old \"vt_\" prefix now fails the strict format" do
      # The exact under-check the old `String.starts_with?(value, "vt_")` missed:
      # a value that starts with "vt_" but is NOT the real 32-hex-char token
      # shape — a leaked plaintext disguised with the prefix.
      record = create!(%{email: "person@example.test", label: "row"})
      leaked = "vt_leak@example.com"
      :ok = plant_email_column!(record, leaked)

      assert_raise ExUnit.AssertionError, @token_shape_msg, fn ->
        Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
          leaked
        ])
      end
    end

    test "a real vt_[0-9a-f]{32} token (positive control) passes the structural assertion" do
      record = create!(%{email: "person@example.test", label: "row"})

      assert :ok =
               Samen.RedPath.assert_vault_routed!(TestRepo, PersonalFixture, record.id, [:email], [
                 "person@example.test"
               ])
    end
  end
end
