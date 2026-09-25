# Drives the guard through the resource that uses it, never naming it in code, so the
# mutation gate cannot back-reference it (scripts/mutation/mutate.exs, OWNING-TEST DERIVATION).
# MUTATION_OWNS: samen_core/lib/samen/vault/change.ex
defmodule Samen.Hardening.VaultChangeFailClosedTest do
  @moduledoc """
  Fail-closed PROOFS for `Samen.Vault.Change` clauses the ADR-049 mutation gate found
  SURVIVING (ledgered ACCEPTED_GAP as MG-11 … MG-17). Each test below is pinned to ONE
  mutation of the shipped source and was verified RED-FIRST by hand: apply the mutation,
  this file's named test fails; restore the file byte-exact, it passes. The shipped
  behaviour is unchanged — only the proof was missing.

  | MG | construct (absolute line on `0216ce8`)                       | mutation      |
  |----|--------------------------------------------------------------|---------------|
  | 11 | `cast_declared_types/1` line 168 `field.composite? and …`    | `and` → `or`  |
  | 12 | `cast_declared_types/1` line 168 `field.type != …Address`    | `!=` → `==`   |
  | 13 | `resolve_subject_id/1` line 244 `changeset.data || %{}`      | `||` → `&&`   |
  | 15 | `ensure_subject_attr/2` line 263 `true ->`                   | `true`→`false`|
  | 16 | `repo!/1` line 277 `repo(resource, :mutate) || …`            | `||` → `&&`   |
  | 17 | `repo!/1` line 278 `… get_env(:vault_repo) || raise`         | `||` → `&&`   |

  (MG-14, `ensure_subject_attr/2` line 257's `changeset.data || %{}`, is NOT closed here —
  see the branch's PR body. On every reachable shape that mutant is behaviourally
  equivalent: it can only differ on an UPDATE, where the `cond`'s fallthrough then
  force-changes the primary key to the value it already holds.)
  """
  use ExUnit.Case, async: false

  alias Samen.Masked
  alias SamenCore.Support.RichTypes.PersonalFixture
  alias SamenCore.TestRepo

  # A country code that is not ISO-3166-1 alpha-2 — `Samen.Type.Address`'s own format
  # rule refuses it, so it only vaults if the Address cast carve-out is skipped.
  @malformed_address %{country: "USA"}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp create(attrs) do
    PersonalFixture
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: Ash.UUID.generate()}, attrs))
    |> Ash.create()
  end

  defp reload!(id) do
    PersonalFixture
    |> Ash.Query.ensure_selected([:email, :address])
    |> Ash.read!()
    |> Enum.find(&(&1.id == id))
  end

  # Fold a changeset's OWN registered `before_action` hooks (the ones the action's changes
  # put there) WITHOUT going through `Ash.Changeset.run_before_actions/1`, which probes the
  # data layer's capabilities first. Only needed by the repo-fallback proof, where the
  # resource's AshPostgres repo is deliberately unresolvable.
  defp fold_before_actions!(changeset) do
    Enum.reduce(changeset.before_action, changeset, fn hook, acc ->
      case hook.(acc) do
        {%Ash.Changeset{} = cs, _instructions} -> cs
        %Ash.Changeset{} = cs -> cs
      end
    end)
  end

  # The subject the ciphertext is filed under — the crypto-shred unit. It MUST be the
  # domain row's own primary key, or `Samen.Erasure.shred/2` (which deletes by subject)
  # would leave the row's ciphertext behind.
  defp vault_subject_of(token) do
    %{rows: rows} =
      TestRepo.query!("SELECT subject_id FROM pii_vault WHERE token = $1", [token])

    case rows do
      [[subject_id]] -> subject_id
      [] -> :no_vault_row
    end
  end

  describe "MG-11 / MG-12 — the composite-EXCEPT-Address cast carve-out (line 168)" do
    test "MG-11/MG-12: a malformed Samen.Type.Address is REFUSED before vaulting" do
      # `:address` is a COMPOSITE pii_attribute whose type IS `Samen.Type.Address`, so the
      # pristine cond falls THROUGH the composite arm into the cast arm and the type's own
      # validation refuses it. `and`→`or` (MG-11) and `!=`→`==` (MG-12) each make the
      # composite arm match this field, skipping the cast — the malformed address would
      # then vault successfully.
      assert {:error, %Ash.Error.Invalid{}} =
               create(%{label: "bad-address", address: @malformed_address})

      # Refused inside the action transaction — no row, no ciphertext.
      assert Ash.read!(PersonalFixture) == []
    end

    test "CONTROL (anti-tautology): a WELL-FORMED Address vaults and reveals normalized" do
      assert {:ok, rec} =
               create(%{label: "ok-address", address: %{city: "Springfield", country: "us"}})

      read_back = reload!(rec.id)
      assert %Masked{} = read_back.address
      assert {:ok, json} = Samen.Vault.reveal(read_back.address, TestRepo)
      assert Jason.decode!(json)["country"] == "US"
    end
  end

  describe "MG-13 — the ciphertext's subject is the row's EXISTING pk on an update (line 244)" do
    test "MG-13: re-vaulting a field on an UPDATE files the ciphertext under the row's own pk" do
      assert {:ok, rec} = create(%{label: "subject", email: "first@example.com"})

      first = reload!(rec.id)
      assert %Masked{token: first_token} = first.email
      assert vault_subject_of(first_token) == rec.id

      # The UPDATE re-vaults the field. `resolve_subject_id/1` must fall back to the
      # EXISTING data pk; `changeset.data || %{}` → `&&` yields `%{}` there, so the
      # mutant generates a FRESH uuid and files the ciphertext under a subject that
      # belongs to no row — invisible to a crypto-shred of this subject.
      assert {:ok, _updated} =
               first
               |> Ash.Changeset.for_update(:update, %{email: "second@example.com"})
               |> Ash.update()

      second = reload!(rec.id)
      assert %Masked{token: second_token} = second.email
      refute second_token == first_token

      assert vault_subject_of(second_token) == rec.id,
             "the re-vaulted ciphertext must be filed under the row's OWN pk, not a fresh subject"
    end
  end

  describe "MG-15 — ensure_subject_attr/2's cond FALLTHROUGH (line 263)" do
    test "MG-15: a CREATE whose pk is UNSET still vaults (the fallthrough forces the subject)" do
      # `Samen.Resource` gives `:id` an Ash-side `default: &Ash.UUID.generate/0`, so an
      # ordinary create already carries a pk change and short-circuits on the cond's
      # SECOND clause. The arm under test is the DB-generated-pk shape the code's own
      # comment names ("On create it may be unset (DB default gen_random_uuid())"): the
      # changeset reaches the vault with NO pk on `data` and NO non-nil pk change, so the
      # `true ->` fallthrough is the only arm that can run and it is what forces the
      # generated subject onto the row. `true`→`false` makes the cond raise
      # CondClauseError and the write dies instead.
      assert {:ok, rec} =
               PersonalFixture
               |> Ash.Changeset.for_create(:create, %{
                 org_id: Ash.UUID.generate(),
                 label: "db-generated-pk",
                 email: "generated@example.com"
               })
               |> Ash.Changeset.force_change_attribute(:id, nil)
               |> Ash.create()

      assert is_binary(rec.id)

      read_back = reload!(rec.id)
      assert %Masked{token: token} = read_back.email

      # The forced pk and the ciphertext's subject are the same value — that is what the
      # fallthrough exists to guarantee.
      assert vault_subject_of(token) == rec.id
    end
  end

  describe "MG-16 — repo!/1 link 1: the resource's own repo (line 277)" do
    setup do
      previous = Application.fetch_env(:samen_core, :vault_repo)
      Application.delete_env(:samen_core, :vault_repo)

      on_exit(fn ->
        case previous do
          {:ok, repo} -> Application.put_env(:samen_core, :vault_repo, repo)
          :error -> Application.delete_env(:samen_core, :vault_repo)
        end
      end)

      :ok
    end

    test "MG-16: a vaulted write resolves the RESOURCE's own repo, with no :vault_repo set" do
      # `resource_repo || config_repo` → `resource_repo && config_repo` is nil once
      # `:vault_repo` is unset, so the chain falls through to the `raise` and this write
      # blows up instead of vaulting.
      refute Application.get_env(:samen_core, :vault_repo),
             "the :vault_repo fallback must be UNSET for this proof to mean anything"

      assert {:ok, rec} = create(%{label: "repo-chain", email: "chain@example.com"})

      read_back = reload!(rec.id)
      assert %Masked{token: token} = read_back.email
      assert vault_subject_of(token) == rec.id
    end
  end

  describe "MG-17 — repo!/1 link 2: the :vault_repo fallback (line 278)" do
    test "MG-17: when the RESOURCE resolves no repo, the write falls back to :vault_repo" do
      assert {:ok, rec} = create(%{label: "fallback", email: "first@example.com"})
      record = reload!(rec.id)

      changeset = Ash.Changeset.for_update(record, :update, %{email: "fallback@example.com"})

      # Make the resource's OWN AshPostgres repo unresolvable (Spark's configurable-option
      # override — `repo` is a configurable DSL option), so link 1 of the chain is nil and
      # the `:vault_repo` fallback is the only thing that can resolve a repo. The DATA LAYER
      # is never reached: only the change's before_action hook runs.
      Application.put_env(:samen_core, PersonalFixture, postgres: [repo: nil])
      on_exit(fn -> Application.delete_env(:samen_core, PersonalFixture) end)

      # Positive controls for the fixture itself: link 1 really is nil, link 2 really is set.
      # Without both, this proof would be vacuous.
      assert AshPostgres.DataLayer.Info.repo(PersonalFixture, :mutate) == nil
      assert Application.get_env(:samen_core, :vault_repo) == TestRepo

      # `(a || b) || raise` → `a || (b && raise)` (`&&` binds tighter): with `a` nil and `b`
      # set, the mutant evaluates the `raise` instead of returning the fallback repo.
      result = fold_before_actions!(changeset)

      assert result.valid?, "the fallback write must succeed, got: #{inspect(result.errors)}"
      assert %Masked{token: token} = Ash.Changeset.get_attribute(result, :email)
      assert vault_subject_of(token) == rec.id
    end
  end
end
