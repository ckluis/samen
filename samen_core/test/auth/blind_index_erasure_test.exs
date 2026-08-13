defmodule Samen.Auth.BlindIndexErasureTest do
  @moduledoc """
  ADR-046 §4.1 (D1) — the blind-index erasure arm (amends ADR-035 §4.1).

  `email_bidx = HMAC(k_bidx, normalize(email))` is keyed on the shared reserved subject
  `"sys:bidx"`, which `Kms.shred/1` refuses permanently — so crypto-shred never reached
  it and an erased subject's email stayed **confirmable forever** via an equality oracle
  (HMAC a candidate email, compare to the stored index). The tombstone arm overwrites
  `email_bidx` with a fresh random unique sentinel on **principal-account** erasure.

  The suite proves, with anti-tautology positive controls:

    * ORACLE DESTROYED — after principal-account erasure, `HMAC(the-erased-email)` no
      longer matches the stored `email_bidx` (now a random sentinel). Positive control:
      BEFORE erasure it DID match (the oracle existed; the test is not vacuous).
    * LIVE LOOKUP PRESERVED — a DIFFERENT, non-erased principal's email still resolves
      via the blind index.
    * RE-REGISTRATION ALLOWED — a fresh signup with the SAME email after erasure succeeds
      (the unique constraint no longer blocks it).
    * SCOPE (the critical safety control) — a per-tenant data-subject shred does NOT
      tombstone the org-less credential's `email_bidx`, so the human's cross-org login
      survives.
  """
  use ExUnit.Case, async: false

  alias Samen.Erasure
  alias Samen.Auth.BlindIndex
  alias Samen.Auth.BlindIndexErasure

  @repo SamenCore.TestRepo

  # Ephemeral credential-shaped table: an org-less principal keyed on its own `id`
  # (its vault subject), with `email_bidx` NOT NULL + UNIQUE (the Credential shape,
  # ADR-035 §3.1/§4.1). Mirrors the real column so the arm's sentinel is proven to
  # fit `allow_nil?: false` + the unique index with no schema change.
  @table "bix_test_credential"
  @spec_ [%{table_name: @table, bidx_column: "email_bidx", subject_column: "id", label: "credential"}]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)
    on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)

    # `id` is `text` here so the raw-SQL inserts bind the string subject_id directly
    # (Postgrex cannot encode a string into a uuid-typed bind param). The arm compares
    # `subject_column::text = $2`, so it treats uuid and text principal keys identically
    # — the real Credential's `id` is uuid; this fixture exercises the same code path.
    Ecto.Adapters.SQL.query!(@repo, """
    CREATE TABLE IF NOT EXISTS #{@table} (
      id text PRIMARY KEY,
      email_bidx text NOT NULL UNIQUE,
      org_id text
    )
    """)

    :ok
  end

  defp insert_principal(id, email_bidx) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "INSERT INTO #{@table} (id, email_bidx) VALUES ($1, $2)",
      [id, email_bidx]
    )
  end

  # Returns the stored email_bidx for `id`, or nil.
  defp stored_bidx(id) do
    case Ecto.Adapters.SQL.query!(@repo, "SELECT email_bidx FROM #{@table} WHERE id = $1", [id]) do
      %{rows: [[v]]} -> v
      %{rows: []} -> nil
    end
  end

  defp uuid, do: Ash.UUID.generate()

  # ======================================================================
  # ORACLE DESTROYED (+ before-erasure positive control)
  # ======================================================================

  test "oracle destroyed: after principal-account erasure HMAC(email) no longer matches the stored index" do
    email = "victim-#{System.unique_integer([:positive])}@example.test"
    cid = uuid()
    {:ok, bidx} = BlindIndex.compute(email)
    insert_principal(cid, bidx)

    # POSITIVE CONTROL (before erasure): the oracle EXISTS — HMAC(email) equals the
    # stored index, so anyone could confirm this subject's email. Proves the test is
    # not vacuous (there is a real oracle to destroy).
    assert stored_bidx(cid) == bidx
    assert {:ok, ^bidx} = BlindIndex.compute(email)

    # Tombstone (principal-account erasure — subject IS the credential owner).
    assert [%{"resource" => "credential", "rows_tombstoned" => 1}] =
             BlindIndexErasure.erase_subject(cid, @repo, bidx_specs: @spec_)

    # ORACLE DESTROYED: the stored value is now a random sentinel — it does NOT equal
    # HMAC(the-erased-email). The email is no longer confirmable.
    after_erasure = stored_bidx(cid)
    refute after_erasure == bidx
    # The HMAC of the email is itself unchanged (k_bidx is shared/un-shreddable) — what
    # changed is the STORED value, so the equality oracle finds nothing.
    assert {:ok, ^bidx} = BlindIndex.compute(email)
    refute BlindIndex.compute(email) == {:ok, after_erasure}

    # Sentinel fits the column shape exactly (64 upper-hex, non-null) — no schema change.
    assert Regex.match?(~r/\A[0-9A-F]{64}\z/, after_erasure)
  end

  # ======================================================================
  # LIVE LOOKUP PRESERVED
  # ======================================================================

  test "live lookup preserved: a different, non-erased principal's email still resolves via the blind index" do
    email_a = "erased-#{System.unique_integer([:positive])}@example.test"
    email_b = "live-#{System.unique_integer([:positive])}@example.test"
    a = uuid()
    b = uuid()
    {:ok, bidx_a} = BlindIndex.compute(email_a)
    {:ok, bidx_b} = BlindIndex.compute(email_b)
    insert_principal(a, bidx_a)
    insert_principal(b, bidx_b)

    # Erase principal A (account deletion).
    assert [%{"rows_tombstoned" => 1}] = BlindIndexErasure.erase_subject(a, @repo, bidx_specs: @spec_)

    # A is un-confirmable; B — a DIFFERENT, live principal — still resolves: its stored
    # index still equals HMAC(email_b), so pre-auth lookup + dedupe are intact for B.
    refute stored_bidx(a) == bidx_a
    assert stored_bidx(b) == bidx_b
    assert {:ok, ^bidx_b} = BlindIndex.compute(email_b)
  end

  # ======================================================================
  # RE-REGISTRATION ALLOWED
  # ======================================================================

  test "re-registration with the same email is allowed after the account is erased" do
    email = "returning-#{System.unique_integer([:positive])}@example.test"
    c1 = uuid()
    {:ok, bidx} = BlindIndex.compute(email)
    insert_principal(c1, bidx)

    assert [%{"rows_tombstoned" => 1}] = BlindIndexErasure.erase_subject(c1, @repo, bidx_specs: @spec_)

    # A fresh signup with the SAME email computes the SAME real index. It must insert
    # WITHOUT tripping the UNIQUE constraint — because c1's index is now a random
    # sentinel, not HMAC(email). (Before the tombstone this INSERT would have raised.)
    c2 = uuid()
    assert %{num_rows: 1} =
             Ecto.Adapters.SQL.query!(
               @repo,
               "INSERT INTO #{@table} (id, email_bidx) VALUES ($1, $2)",
               [c2, bidx]
             )

    assert stored_bidx(c2) == bidx
    refute stored_bidx(c1) == bidx
  end

  # ======================================================================
  # SCOPE — the critical safety control (per-tenant shred does NOT tombstone)
  # ======================================================================

  test "per-tenant data-subject shred does NOT tombstone the credential's email_bidx (cross-org login survives)" do
    email = "human-#{System.unique_integer([:positive])}@example.test"
    cid = uuid()
    {:ok, bidx} = BlindIndex.compute(email)
    insert_principal(cid, bidx)

    # A per-tenant data-subject shred erases a per-org record (an Identity.User row),
    # whose subject_id is the USER's own id — NOT the org-less Credential's id. The arm
    # matches index rows on the OWNER's own key, so this shred matches ZERO credential
    # rows: the shared login credential is untouched.
    data_subject_id = uuid()
    refute data_subject_id == cid

    assert {:ok, %{report: report}} =
             Erasure.shred(data_subject_id, repo: @repo, bidx_specs: @spec_)

    # The credential's index is UNCHANGED — the human's cross-org login survives, and
    # the email still resolves via the blind index.
    assert stored_bidx(cid) == bidx
    assert {:ok, ^bidx} = BlindIndex.compute(email)

    # The erasure report's blind_index tier shows the arm ran but tombstoned NOTHING
    # (no owning principal matched) — the safety property, on the record.
    assert [%{"resource" => "credential", "rows_tombstoned" => 0}] = report.tiers["blind_index"]
  end

  # ======================================================================
  # FULL Erasure.shred integration — principal-account erasure reaches the index
  # ======================================================================

  test "Erasure.shred integration: principal-account shred tombstones email_bidx and reports the blind_index tier" do
    email = "principal-#{System.unique_integer([:positive])}@example.test"
    cid = uuid()
    {:ok, bidx} = BlindIndex.compute(email)
    insert_principal(cid, bidx)

    # Give the principal a vaulted field so the shred has real DB-tier work too.
    {:ok, _t} = Samen.Vault.store_field(cid, :pii_secret, :totp_secret, "SEKRET", @repo)

    assert {:ok, %{report: report}} = Erasure.shred(cid, repo: @repo, bidx_specs: @spec_)

    # The blind-index arm is on the erasure report (token-only) AND actually reached the
    # column: the stored index no longer equals HMAC(email).
    assert [%{"resource" => "credential", "rows_tombstoned" => 1}] = report.tiers["blind_index"]
    refute stored_bidx(cid) == bidx
    assert Regex.match?(~r/\A[0-9A-F]{64}\z/, stored_bidx(cid))
  end
end
