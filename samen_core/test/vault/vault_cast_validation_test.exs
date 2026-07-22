defmodule Samen.Vault.CastValidationTest do
  @moduledoc """
  ADR-036 D3 conformance (T99): the vaulted write path re-runs the DECLARED logical
  type's `cast_input` (validation AND normalization) before the plaintext reaches the
  vault.

  This is the PERMANENT home of the probe the T13 verifier ran throwaway
  (`_orch/verify/T13-verdict.json` → `probe`): before this fix,
  `Samen.Transformers.MaterializePii` swapped every `pii_attribute`'s declared type
  for `Samen.Type.VaultField` (identity `cast_input`) and `Samen.Vault.Change` only
  stringified, so a garbage email VAULTED SUCCESSFULLY and revealed byte-for-byte —
  contradicting ADR-036 D3 ("the value is validated on input"). These tests are RED
  before the `Samen.Vault.Change` fix and GREEN after; each is paired with a positive
  control (anti-tautology — a test that cannot fail is a bug).

  The declared-type validation runs where the plaintext lives on the vaulted write
  path — `Samen.Vault.Change`, via `Ash.Type.cast_input/2` (the SAME entry point Ash
  uses to cast an ordinary plaintext attribute of that type), so a vaulted value and a
  bare-plaintext value of the same declared type round-trip to the SAME canonical form.

  ## T14 addition — `Samen.Type.Address` (ADR-036 §10 addendum, binding, post-T99)

  T99 scoped this gate to SCALAR validating types and left COMPOSITE PII types
  (`FullName`/`Emails`/`Phones`) unvalidated on the vaulted write path (see the §10
  addendum's "Scope" section) — gating them would reject `Invitation.email`'s shipped
  loose-shape write, a cross-cutting cleanup out of a surgical fix's surface. The
  addendum's forward note gave T14 two options: (a) land that writer cleanup and flip
  ALL composites into this gate, or (b) validate `Address` — a BRAND NEW composite
  type with no shipped loose writers to break — at its own input boundary. T14 took
  (b) (the prime orchestrator's binding ruling, since T05 concurrently works the
  Invitation/Emails surface option (a) would touch): `Samen.Vault.Change` carries a
  narrow, Address-specific carve-out (by module identity, not a `composite?` flip) so
  a malformed Address is refused here exactly like a scalar — the tests below are the
  Address analogue of the garbage-email probe above. FullName/Emails/Phones are
  UNTOUCHED (verified indirectly: this file's SCALAR tests above are unaffected, and
  `Samen.Type.AddressTest` proves Address casts identically on the vaulted and
  bare-plaintext paths, matching this file's phone-normalization parity pattern).
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias Samen.Vault
  alias SamenCore.Support.RichTypes.{OrgFixture, PersonalFixture}
  alias SamenCore.TestRepo

  # The exact probe vector from the T13 verdict.
  @garbage_email "this is not an email at all !!!"
  # The URL red vector named in the T99 handoff (parses, but scheme is out of allowlist).
  @danger_url "javascript:alert(1)"
  # The Address analogue (T14, ADR-036 §10 addendum): a country code that is not a
  # two-letter ISO-3166-1 alpha-2 code — Address's own format rule.
  @garbage_address %{country: "USA"}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  defp create(attrs) do
    PersonalFixture
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: Ash.UUID.generate()}, attrs))
    |> Ash.create()
  end

  defp read_all do
    PersonalFixture
    |> Ash.Query.ensure_selected([:email, :phone, :profile_url, :address])
    |> Ash.read!()
  end

  describe "RED (permanent) — a value the declared type rejects must NOT vault (ADR-036 D3)" do
    test "the T13 garbage-email probe: Ash.create is REFUSED with a cast/validation error" do
      assert {:error, %Ash.Error.Invalid{}} = create(%{label: "garbage", email: @garbage_email})

      # It did not vault: no row was written (the change aborted inside the action's
      # transaction, the DB is unchanged).
      assert read_all() == []
    end

    test "the URL red vector (javascript: is out of the scheme allowlist) is REFUSED" do
      assert {:error, %Ash.Error.Invalid{}} = create(%{label: "danger", profile_url: @danger_url})
      assert read_all() == []
    end

    test "POSITIVE CONTROL (anti-tautology): a VALID email on the same attribute vaults fine" do
      assert {:ok, rec} = create(%{label: "ok", email: "grace@example.com"})
      assert %Masked{} = Enum.find(read_all(), &(&1.id == rec.id)).email
    end

    # T14 (ADR-036 §10 addendum, binding — option (b), own-boundary validation):
    # the Address analogue of the garbage-email probe above. Full contract
    # coverage lives in `Samen.Type.AddressTest`; these two are the PERMANENT
    # vault-write-path proof, alongside the scalar ones this file already carries.
    test "the T14 garbage-Address probe: a 3-letter country code is REFUSED, DB unchanged" do
      assert {:error, %Ash.Error.Invalid{}} =
               create(%{label: "garbage-address", address: @garbage_address})

      assert read_all() == []
    end

    test "POSITIVE CONTROL (anti-tautology): a VALID Address on the same attribute vaults fine" do
      assert {:ok, rec} =
               create(%{label: "ok-address", address: %{city: "Springfield", country: "US"}})

      assert %Masked{} = Enum.find(read_all(), &(&1.id == rec.id)).address
    end
  end

  describe "POSITIVE CONTROL — a valid vaulted value normalizes on the way in" do
    test "valid email vaults, reads back %Masked{}, reveal returns the cast-normalized value" do
      # A stray surrounding-whitespace input proves normalization (cast_input trims);
      # the vault stores the NORMALIZED value, not the raw input string.
      {:ok, rec} = create(%{label: "grace", email: "  grace@example.com  "})

      read_back = Enum.find(read_all(), &(&1.id == rec.id))
      assert %Masked{} = read_back.email
      refute read_back.email == "  grace@example.com  "

      assert {:ok, "grace@example.com"} = Vault.reveal(read_back.email, TestRepo)
    end
  end

  describe "PHONE NORMALIZATION PARITY — vaulted path == org-plaintext path (ADR-036 D3)" do
    test "vaulting \"+1-555-010-0100\" reveals \"+15550100100\" — identical to the plaintext path" do
      {:ok, rec} = create(%{label: "grace", phone: "+1-555-010-0100"})
      read_back = Enum.find(read_all(), &(&1.id == rec.id))

      assert %Masked{} = read_back.phone
      assert {:ok, vaulted_normalized} = Vault.reveal(read_back.phone, TestRepo)
      assert vaulted_normalized == "+15550100100"

      # The org-level PLAINTEXT path (a bare `attribute … Samen.Type.PhoneNumber`)
      # normalizes the SAME input identically — parity between the two write paths.
      org =
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          name: "acme",
          support_phone: "+1-555-010-0100"
        })
        |> Ash.create!()

      assert org.support_phone == vaulted_normalized
    end
  end

  describe "ADDRESS NORMALIZATION PARITY — vaulted path == plain-attribute path (T14, ADR-036 §10 addendum)" do
    test "vaulting a lowercase country reveals it UPPERCASED — identical to the plain-attribute path" do
      {:ok, rec} = create(%{label: "grace", address: %{city: "Springfield", country: "us"}})
      read_back = Enum.find(read_all(), &(&1.id == rec.id))

      assert %Masked{} = read_back.address
      assert {:ok, vaulted_json} = Vault.reveal(read_back.address, TestRepo)
      assert Jason.decode!(vaulted_json)["country"] == "US"

      # The org-level PLAIN-ATTRIBUTE path (a bare `attribute … Samen.Type.Address`,
      # OrgFixture.billing_address) normalizes the SAME input identically — parity
      # between the two write paths, same guarantee PhoneNumber proves above.
      org =
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          name: "acme",
          billing_address: %{city: "Springfield", country: "us"}
        })
        |> Ash.create!()

      assert org.billing_address.country == "US"
    end
  end
end
