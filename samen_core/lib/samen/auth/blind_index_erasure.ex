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

  ## Wired by construction, from the live schema (no host config to forget)

  The kernel does not know a host's Credential/Invitation table names (materialized per-host with
  host-specific abbrevs), so the arm is a list of specs. They are DERIVED from the host's own
  resources AT ERASURE TIME (`derived_specs/1`: every registered derived-linkable `_bidx` column of
  `Samen.DerivedLinkable`, keyed on its owning principal), unioned with anything a host still lists
  under `config :samen_core, :blind_index_erasure_specs`. A host that never called
  `Samen.Erasure.install_default_specs/1` is therefore covered all the same. Each spec is a map:

      %{
        table_name:     "cmp_credential",  # the physical (abbrev-prefixed) table
        bidx_column:    "email_bidx",      # the blind-index column (default "email_bidx")
        subject_column: "id",              # the owning-principal key (default "id")
        label:          "credential"       # optional; for the token-only report
      }

  A `:bidx_specs` option replaces the whole list (tests of one fixture table).

  ### Fail-honest

  Erasure that cannot clear a blind index must not report success. Unless `:bidx_specs` is given, the
  arm checks the live schema first: a `_bidx` column that is not registered in `Samen.DerivedLinkable`
  (so no arm can be derived for it) raises, the erasure transaction rolls back, and the operator
  sees the column named. The subject's DEK is destroyed before the transaction; a retry is safe.

  ### Login-failure counters

  `Identity.LoginFailure` keys its brute-force counters on the person's `email_bidx` (and on the
  credential id): a keyed hash of the erased person's email, in a table the `_bidx` column scan
  cannot see. When a principal-account erasure tombstones a row, the arm first reads the old index
  values, then deletes every counter keyed on them (and on the credential id).

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

    * `:bidx_specs` — replace the specs (and skip the live-schema coverage check; tests of one fixture
      table pass this), with `:login_failure_specs` the counter tables to purge alongside;
    * `:resources` / `:domains` / `:otp_app` — which resources to derive from (default: the app's
      `:ash_domains`).

  Fires only where `subject_column == subject_id` — i.e. only when `subject_id` IS the
  owning principal (a principal-account erasure); a per-tenant data-subject shred
  matches zero rows (see the module doc). Returns a per-spec report list (each entry a
  token-only map) the erasure report embeds.
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) do
    {specs, login_failures} =
      case Keyword.get(opts, :bidx_specs) do
        nil ->
          resources = Samen.Erasure.Completeness.resources(Keyword.take(opts, [:resources, :domains, :otp_app]))
          assert_covered!(resources)
          configured = Application.get_env(:samen_core, :blind_index_erasure_specs, [])
          {Enum.uniq_by(configured ++ derived_specs(resources), &spec_key/1), login_failure_tables(resources)}

        explicit ->
          {explicit, Keyword.get(opts, :login_failure_specs, [])}
      end

    reports = Enum.map(specs, &tombstone_one(&1, subject_id, repo))

    if Enum.any?(reports, &(&1["rows_tombstoned"] > 0)) do
      purge_login_failures(login_failures, subject_id, reports, repo)
    end

    Enum.map(reports, &Map.delete(&1, "old_values"))
  end

  defp spec_key(spec),
    do: {to_string(spec.table_name), to_string(Map.get(spec, :bidx_column, "email_bidx")), to_string(Map.get(spec, :subject_column, "id"))}

  @doc """
  The blind-index erasure specs for `resources`, derived from the live schema: one per REGISTERED
  derived-linkable column (`Samen.DerivedLinkable`). An unregistered `_bidx` column yields no spec;
  `uncovered/1` names it.
  """
  @spec derived_specs([module()]) :: [map()]
  def derived_specs(resources) do
    for r <- Samen.DerivedLinkable.discover(resources), r.registered?, r.subject_column != nil do
      %{
        table_name: r.table,
        bidx_column: r.column,
        subject_column: r.subject_column,
        label: r.resource |> Module.split() |> Enum.take(-2) |> Enum.join(".")
      }
    end
  end

  @doc """
  The blind-index columns in `resources` that erasure does NOT cover: every `_bidx` column of the live
  schema that is not a registered derived-linkable column with a resolvable owning key. `[]` means
  every one is covered. (The guard tests assert `[]` per host.)
  """
  @spec uncovered([module()]) :: [{module(), atom()}]
  def uncovered(resources) do
    for r <- Samen.DerivedLinkable.discover(resources), not r.registered? or r.subject_column == nil do
      {r.resource, r.logical}
    end
  end

  defp assert_covered!(resources) do
    case uncovered(resources) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "blind-index erasure cannot clear #{inspect(missing)}: register the column in " <>
                "Samen.DerivedLinkable (erasure would otherwise report success and leave a keyed hash " <>
                "of the erased person's email in place)"
    end
  end

  @doc """
  The `LoginFailure`-shaped tables among `resources` (a `key_kind` + `key_value` pair): the counters
  keyed on an email blind index or a credential id that a principal-account erasure must purge.
  """
  @spec login_failure_tables([module()]) :: [map()]
  def login_failure_tables(resources) do
    for resource <- resources,
        kind = Ash.Resource.Info.attribute(resource, :key_kind),
        value = Ash.Resource.Info.attribute(resource, :key_value),
        table = AshPostgres.DataLayer.Info.table(resource) do
      %{
        table_name: table,
        kind_column: to_string(kind.source || kind.name),
        value_column: to_string(value.source || value.name)
      }
    end
  end

  defp purge_login_failures(tables, subject_id, reports, repo) do
    old_values = reports |> Enum.flat_map(&Map.get(&1, "old_values", [])) |> Enum.uniq()

    for t <- tables do
      table = safe_ident!(t.table_name)
      kind = safe_ident!(t.kind_column)
      value = safe_ident!(t.value_column)

      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM #{table} WHERE (#{kind} = 'email_bidx' AND #{value} = ANY($1)) OR (#{kind} = 'credential' AND #{value} = $2)",
        [old_values, subject_id]
      )
    end

    :ok
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
    # The index values about to be overwritten: the login-failure counters are keyed on them.
    %{rows: old_rows} =
      Ecto.Adapters.SQL.query!(repo, "SELECT #{column} FROM #{table} WHERE #{subject_column}::text = $1", [subject_id])

    old_values = for [v] <- old_rows, is_binary(v), do: v

    sql =
      "UPDATE #{table} SET #{column} = $1 " <>
        "WHERE #{subject_column}::text = $2"

    %{num_rows: n} = Ecto.Adapters.SQL.query!(repo, sql, [sentinel, subject_id])

    %{"resource" => label, "rows_tombstoned" => n, "old_values" => old_values}
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
