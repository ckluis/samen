defmodule Samen.Auth.BlindIndexErasure do
  @moduledoc """
  The **blind-index erasure arm** (ADR-046 §4.1 · D1; amends ADR-035 §4.1) — the arm
  that makes crypto-shred reach the recomputable `email_bidx` HMAC.

  `Samen.Erasure.shred/2` is a key-destruction job: it destroys the subject's DEK so
  every *vaulted* value becomes undecryptable at once. But `email_bidx =
  Base.encode16(HMAC-SHA256(k_bidx, normalize(email)))` (`Samen.Auth.BlindIndex`) is
  keyed on the shared reserved subject `"sys:bidx"`, which `Samen.Kms.shred/1` refuses
  to destroy by design (shredding it would break every login, not erase one subject).
  So the index lives OUTSIDE the per-subject-DEK envelope — the same class of residue
  as the `non_pii!` plaintext carve-out and the file-blob carve-out. Left untouched, a
  shredded subject's email stays **confirmable forever**: anyone with DB + `k_bidx`
  access HMACs a candidate email and compares it to the stored index (an equality
  oracle over the enumerable email space).

  This module is that carve-out's erasure arm. On shred of a subject it **tombstones**
  `email_bidx` — overwriting it with a fresh 32-byte random unique sentinel rendered to
  the SAME 64-hex shape the column already holds (`Base.encode16(strong_rand_bytes(32),
  case: :upper)`). The sentinel has no `HMAC(email)` preimage, so the equality oracle
  finds nothing for the erased subject, while:

    * **Pre-auth lookup is preserved for LIVE subjects** — sign-in HMACs the entered
      email and finds a live credential; an erased subject's random sentinel simply
      does not match (correct: the account is gone).
    * **Dedupe (one-account-per-email) is preserved for LIVE subjects** — every live
      subject's real index is untouched.
    * **Re-registration with the same email is allowed** — the old row's index is now
      random, so the `allow_nil?: false` + unique constraint no longer blocks a fresh
      signup under that email.

  The sentinel is the same shape and non-null, so it satisfies `allow_nil?: false` and
  the unique index with **NO schema migration and no `allow_nil` relaxation**.

  ## Principal-account erasure ONLY — the load-bearing scoping (ADR-035 §4.1 amendment)

  A `Samen.Identity.Credential` is **org-LESS — one human, N orgs** (ADR-035 §3.1). A
  per-tenant *data-subject* shred (e.g. a tenant erasing one of their `Identity.User`
  rows, or a driftwood CDL holder) must **NEVER** touch the shared login credential —
  doing so would break that human's login to their *other* orgs.

  This arm fires **only when the erased subject IS the principal that owns the index
  row** — a full *account* deletion — never a per-org data-subject shred. It achieves
  this structurally, not by a flag: it matches index rows on the row's **own subject
  column** (`subject_column`, default `"id"`), and a Credential/Invitation vaults its
  own material under `subject_id == its primary key` (`Samen.Vault.Change` keys the
  vault on the row's pk — `vault/change.ex`; Credential's TOTP secret binds
  `subject_id: credential_id`). Therefore:

    * A **principal-account erasure** shreds `subject_id == credential.id` → the arm
      matches that Credential row and tombstones its `email_bidx`.
    * A **per-tenant data-subject shred** shreds `subject_id == user.id` → no Credential
      row has `id == user.id` (distinct resources, distinct UUID pks), so the arm
      matches **zero rows** and is a no-op. The human's Credential — and thus their
      cross-org login — is untouched.

  So `subject_column` MUST be the owning principal's key (the row's own pk). Pointing it
  at any other column is a misconfiguration that would break the scoping guarantee.

  ## Spec-driven, framework-first (the registry)

  The kernel does not know a host's Credential/Invitation table names (materialized
  per-host with host-specific abbrevs), so the arm is expressed as a list of specs the
  host registers (`config :samen_core, :blind_index_erasure_specs`), exactly like the
  file-erasure and rollup-erasure registries. Each spec is a map:

      %{
        table_name:     "cmp_credential",  # the physical (abbrev-prefixed) table
        bidx_column:    "email_bidx",      # the blind-index column (default "email_bidx")
        subject_column: "id",              # the owning-principal key (default "id")
        label:          "credential"       # optional; for the token-only report
      }

  Absent any spec the arm is a no-op (returns `[]`) — a host that has not registered the
  blind-index arm is unchanged, exactly as `Samen.NonPii` redacts nothing until a column
  is registered. (The forthcoming erasure-completeness verifier (ADR-046 §6) will assert
  every `email_bidx` column has such an arm, so a future one cannot ship unregistered.)

  ## Fail-closed, in the erasure transaction

  This arm is a pure in-DB `UPDATE` on the erasure transaction's own repo (no external
  system), so it runs **inside** `Samen.Erasure.shred/2`'s transaction and is
  **fail-closed**: a failure (e.g. a spec naming a table not in this repo) raises and
  rolls the transaction back — the operator retries; the subject's DEK is already
  destroyed, so no PII is at risk, and the tombstone is not silently skipped (the exact
  hole a "make it pass" shortcut would open).

  SECURITY NOTE: `table_name`/`bidx_column`/`subject_column` come from the registry,
  populated only by a host's config from developer-controlled identifiers (never
  end-user input). They are still validated as safe SQL identifiers before
  interpolation (`safe_ident!/1`), and the sentinel + subject values are bound
  parameters.
  """

  @sentinel_bytes 32

  @doc """
  Tombstone `email_bidx` for `subject_id` across every registered blind-index spec.

  `repo` is the erasure transaction's repo. `opts`:

    * `:bidx_specs` — override the registered specs (tests pass this).

  Fires only where `subject_column == subject_id` — i.e. only when `subject_id` IS the
  owning principal (a principal-account erasure); a per-tenant data-subject shred
  matches zero rows (see the module doc). Returns a per-spec report list (each entry a
  token-only map) the erasure report embeds.
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) do
    specs =
      Keyword.get(opts, :bidx_specs) ||
        Application.get_env(:samen_core, :blind_index_erasure_specs, [])

    Enum.map(specs, &tombstone_one(&1, subject_id, repo))
  end

  @doc """
  A fresh random blind-index sentinel: a 32-byte random rendered to the same 64-upper-hex
  shape a real `email_bidx` holds (so it fits `allow_nil?: false` + the unique index with
  no schema change). It has no `HMAC(email)` preimage — the equality oracle finds nothing.
  """
  @spec fresh_sentinel() :: String.t()
  def fresh_sentinel do
    Base.encode16(:crypto.strong_rand_bytes(@sentinel_bytes), case: :upper)
  end

  defp tombstone_one(spec, subject_id, repo) do
    table = safe_ident!(Map.fetch!(spec, :table_name))
    column = safe_ident!(Map.get(spec, :bidx_column, "email_bidx"))
    subject_column = safe_ident!(Map.get(spec, :subject_column, "id"))
    label = to_string(Map.get(spec, :label, table))

    sentinel = fresh_sentinel()

    # Cast the subject column to text so both `:uuid` and `:text` principal keys compare
    # against the string subject_id without Postgrex needing a uuid-binary encode. The
    # `subject_column = id` match is what scopes this to principal-account erasure only.
    sql =
      "UPDATE #{table} SET #{column} = $1 " <>
        "WHERE #{subject_column}::text = $2"

    %{num_rows: n} = Ecto.Adapters.SQL.query!(repo, sql, [sentinel, subject_id])

    %{"resource" => label, "rows_tombstoned" => n}
  end

  # A physical identifier must be a plain snake_case token. Hard gate, not sanitization —
  # anything with a quote/space/paren/semicolon is refused. (Mirrors `Samen.NonPii`.)
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in blind_index_erasure spec: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end
end
