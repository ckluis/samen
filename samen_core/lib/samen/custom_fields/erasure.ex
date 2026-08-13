defmodule Samen.CustomFields.Erasure do
  @moduledoc """
  The **Tier-1 custom-bag erasure arm** (ADR-046 §4.2 · D3) — the arm that makes
  crypto-shred reach `pii_declared: true` plaintext PII stored in a resource's
  `<abbrev>_custom` jsonb bag.

  `Samen.Erasure.shred/2` is a key-destruction job: it makes every *vaulted* value
  for a subject undecryptable at once. But a Tier-1 field declared `pii_declared: true`
  stores its value as **plaintext in the sealed jsonb bag, never routed to the vault**
  (`Samen.CustomFields.FieldRow` moduledoc — the honest seam). That plaintext lives
  OUTSIDE the per-subject-DEK envelope, so key-shred does not reach it — the same class
  of residue as the `non_pii!` plaintext carve-out, the file-blob carve-out, and the
  `email_bidx` blind index.

  `Samen.NonPii` redacts whole *columns*; the bag is ONE `:map` column with many keys,
  only SOME of which are pii_declared. So this arm does **per-KEY** redaction: on shred
  of a subject it removes exactly the org's `tnt_pii_declared: true` keys from that
  subject's bag rows (`jsonb - text[]`), leaving every non-PII key intact.

  ## Which keys — read from the org's `tnt_field` catalog

  `pii_declared` is a RUNTIME per-org fact (an org turns it on via
  `Samen.CustomFields.define_field(…, pii_declared: true)`), so the arm reads the
  key set from the org's `tnt_field` rows (the SAME catalog the masking resolver
  reads — `Samen.Api.PiiResolution`). It groups the subject's rows by org and removes
  that org's pii_declared keys, so a multi-org subject is handled correctly.

  ## Spec-driven, framework-first (the registry)

  The kernel does not know a host's resource modules / physical column names, so the
  arm is expressed as a list of specs the host registers
  (`config :samen_core, :custom_bag_erasure_specs`), exactly like the file-erasure and
  blind-index-erasure registries. Each spec is a map:

      %{
        table_name:     "per_person",  # the physical (abbrev-prefixed) table
        bag_column:     "per_custom",  # the jsonb bag column (default "custom")
        subject_column: "per_id",      # the column carrying the data-subject id (default "id")
        org_column:     "per_org_id",  # the org column (default "org_id")
        label:          "person"       # optional; for the token-only report
      }

  Absent any spec the arm is a no-op (returns `[]`) — a host that has not registered
  it is unchanged. This is why `Samen.CustomFields.define_field/2` **refuses**
  `pii_declared: true` unless an erasure spec covers the table (the fail-closed guard):
  a pii_declared bag cannot exist without a registered arm to erase it, so the arm is
  never absent for a live pii_declared field.

  ## Fail-closed, in the erasure transaction

  This arm is a pure in-DB `UPDATE` on the erasure transaction's own repo (no external
  system), so it runs **inside** `Samen.Erasure.shred/2`'s transaction and is
  **fail-closed**: a failure (e.g. a spec naming a table not in this repo) raises and
  rolls the transaction back — the subject's DEK is already destroyed, so no PII is at
  risk, and the redaction is not silently skipped.

  SECURITY NOTE: `table_name`/`bag_column`/`subject_column`/`org_column` come from the
  registry (developer-controlled config identifiers, never end-user input). They are
  still validated as safe SQL identifiers (`safe_ident!/1`); the key list and subject/org
  values are bound parameters.
  """

  alias Samen.CustomFields

  @doc """
  Redact the `pii_declared` bag keys of `subject_id` across every registered
  custom-bag spec.

  `repo` is the erasure transaction's repo. `opts`:

    * `:custom_bag_specs` — override the registered specs (tests pass this).

  Returns a per-spec report list (each entry a token-only map) the erasure report embeds.
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) do
    specs =
      Keyword.get(opts, :custom_bag_specs) ||
        Application.get_env(:samen_core, :custom_bag_erasure_specs, [])

    Enum.map(specs, &redact_one_spec(&1, subject_id, repo))
  end

  defp redact_one_spec(spec, subject_id, repo) do
    table = safe_ident!(Map.fetch!(spec, :table_name))
    bag_col = safe_ident!(Map.get(spec, :bag_column, "custom"))
    subject_col = safe_ident!(Map.get(spec, :subject_column, "id"))
    org_col = safe_ident!(Map.get(spec, :org_column, "org_id"))
    label = to_string(Map.get(spec, :label, table))

    # Group the subject's rows by org (a subject may — in principle — span orgs), so
    # each row is redacted against ITS org's pii_declared key set.
    org_sql = "SELECT DISTINCT #{org_col}::text FROM #{table} WHERE #{subject_col}::text = $1"
    %{rows: org_rows} = Ecto.Adapters.SQL.query!(repo, org_sql, [subject_id])
    org_ids = for [o] <- org_rows, not is_nil(o), do: o

    {rows_redacted, keys_removed} =
      Enum.reduce(org_ids, {0, MapSet.new()}, fn org_id, {racc, kacc} ->
        case pii_declared_keys(org_id, table, repo) do
          [] ->
            {racc, kacc}

          keys ->
            # jsonb `- text[]` removes every listed key from the bag; non-PII keys
            # (and the non-matching rows) are untouched.
            sql =
              "UPDATE #{table} SET #{bag_col} = COALESCE(#{bag_col}, '{}'::jsonb) - $1::text[] " <>
                "WHERE #{subject_col}::text = $2 AND #{org_col}::text = $3"

            %{num_rows: n} = Ecto.Adapters.SQL.query!(repo, sql, [keys, subject_id, org_id])
            {racc + n, Enum.reduce(keys, kacc, &MapSet.put(&2, &1))}
        end
      end)

    %{
      "resource" => label,
      "rows_redacted" => rows_redacted,
      "keys_redacted" => MapSet.size(keys_removed)
    }
  end

  # The org's `tnt_pii_declared: true` bag keys for this table — the SAME catalog the
  # masking resolver reads. Reuses the tested `Samen.CustomFields.list_fields/3`.
  defp pii_declared_keys(org_id, table, repo) do
    org_id
    |> CustomFields.list_fields(table, repo)
    |> Enum.filter(& &1.tnt_pii_declared)
    |> Enum.map(& &1.tnt_field_name)
  end

  # A physical identifier must be a plain snake_case token. Hard gate, not sanitization
  # (mirrors `Samen.NonPii` / `Samen.Auth.BlindIndexErasure`).
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in custom_bag_erasure spec: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end
end
