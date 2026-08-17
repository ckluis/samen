defmodule Samen.CustomObjects.Erasure do
  @moduledoc """
  The **Tier-2 custom-OBJECT record-bag erasure arm** (ADR-046 §8 residual #2) — the
  analogue of `Samen.CustomFields.Erasure` for a tenant-defined custom object's records.

  `Samen.Erasure.shred/2` is a key-destruction job: it makes every *vaulted* value for a
  subject undecryptable at once. A custom-object field declared `pii_declared: true` stores
  its value as **plaintext in the `tnt_record` `attributes` bag, never routed to the vault**
  — that plaintext lives OUTSIDE the per-subject-DEK envelope, so key-shred does not reach
  it, exactly like a first-class resource's Tier-1 `pii_declared` bag. `Samen.CustomFields`'
  arm redacts a *physical* resource's `:custom` column; a custom OBJECT stores its rows in
  the shared `tnt_record` table keyed by `object_key`, so it needs its own arm keyed the same
  way. This is that arm: on shred of a subject it removes exactly the object's
  `tnt_pii_declared: true` keys from the subject's `tnt_record` rows (`jsonb - text[]`),
  leaving every non-PII key intact.

  ## The define-time discipline this arm backs

  `Samen.CustomFields.define_field/2` REFUSES a `pii_declared: true` custom-object field
  unless a `:record_bag_erasure_specs` entry covers its object (the guard's `tnt$obj$…`
  rung) — so a live pii_declared custom-object field can never exist without this arm
  registered to erase it, closing the escape ADR-046 §8 residual #2 named.

  ## Subject linkage — via the record's opaque `refs` OUT-reference

  A `tnt_record` carries no physical subject column; it references a system data subject
  through its opaque `refs` bag (`Samen.CustomObjects.RecordChange` validates every ref as
  an opaque ID). So a record *about* a data subject names them under a `refs` key (e.g.
  `refs: %{"subject" => "<person_uuid>"}`), and the spec's `:subject_ref_key` says which
  key — the arm reaches the subject's rows via `refs ->> subject_ref_key = subject_id`.

  ## Spec-driven, framework-first (the registry)

  Expressed as a list of specs the host registers
  (`config :samen_core, :record_bag_erasure_specs`), exactly like the file / blind-index /
  custom-bag registries. Each spec is a map:

      %{
        object_key:        "contact_note",   # the custom object (required)
        subject_ref_key:   "subject",        # the refs key naming the data subject (required)
        record_table:      "tnt_record",     # physical table (default)
        bag_column:        "tnr_attributes", # the jsonb attributes bag (default)
        refs_column:       "tnr_refs",       # the jsonb refs bag (default)
        org_column:        "tnr_org_id",     # the org column (default)
        object_key_column: "tnr_object_key", # the object-key discriminator (default)
        label:             "contact_note"    # optional; for the token-only report
      }

  Absent any spec the arm is a no-op (returns `[]`). The `pii_declared` keys are read from
  the org's `tnt_field` catalog under the object's synthetic table name
  (`Samen.CustomObjects.object_table/1`) — the SAME catalog the masking resolver reads.

  ## Fail-closed, in the erasure transaction

  A pure in-DB `UPDATE` on the erasure transaction's own repo (no external system), so it
  runs **inside** `Samen.Erasure.shred/2`'s transaction and is **fail-closed**: a failure
  (e.g. a spec naming a table not in this repo) raises and rolls the transaction back — the
  subject's DEK is already destroyed, so no PII is at risk, and the redaction is not silently
  skipped.

  SECURITY NOTE: `record_table`/`bag_column`/`refs_column`/`org_column`/`object_key_column`
  come from the registry (developer-controlled config identifiers, never end-user input).
  They are still validated as safe SQL identifiers (`safe_ident!/1`); the object key, subject
  id, org, and ref-key are bound parameters.
  """

  alias Samen.CustomFields
  alias Samen.CustomObjects

  @doc """
  Redact the `pii_declared` record-bag keys of `subject_id` across every registered
  record-bag spec.

  `repo` is the erasure transaction's repo. `opts`:

    * `:record_bag_specs` — override the registered specs (tests pass this).

  Returns a per-spec report list (each entry a token-only map) the erasure report embeds.
  """
  @spec erase_subject(String.t(), module(), keyword()) :: [map()]
  def erase_subject(subject_id, repo, opts \\ []) when is_binary(subject_id) do
    specs =
      Keyword.get(opts, :record_bag_specs) ||
        Application.get_env(:samen_core, :record_bag_erasure_specs, [])

    Enum.map(specs, &redact_one_spec(&1, subject_id, repo))
  end

  defp redact_one_spec(spec, subject_id, repo) do
    object_key = to_string(Map.fetch!(spec, :object_key))
    subject_ref_key = to_string(Map.fetch!(spec, :subject_ref_key))
    record_table = safe_ident!(Map.get(spec, :record_table, "tnt_record"))
    bag_col = safe_ident!(Map.get(spec, :bag_column, "tnr_attributes"))
    refs_col = safe_ident!(Map.get(spec, :refs_column, "tnr_refs"))
    org_col = safe_ident!(Map.get(spec, :org_column, "tnr_org_id"))
    object_key_col = safe_ident!(Map.get(spec, :object_key_column, "tnr_object_key"))
    label = to_string(Map.get(spec, :label, object_key))

    # The object's synthetic tnt_field table name — used ONLY as a bound param (never
    # interpolated), so its `$` sentinel is safe. This is where the object's pii_declared
    # field defs live.
    object_table = CustomObjects.object_table(object_key)

    # Group the subject's records (for THIS object) by org, so each row is redacted against
    # ITS org's pii_declared key set.
    org_sql =
      "SELECT DISTINCT #{org_col}::text FROM #{record_table} " <>
        "WHERE #{object_key_col}::text = $1 AND #{refs_col} ->> $2 = $3"

    %{rows: org_rows} = Ecto.Adapters.SQL.query!(repo, org_sql, [object_key, subject_ref_key, subject_id])
    org_ids = for [o] <- org_rows, not is_nil(o), do: o

    {rows_redacted, keys_removed} =
      Enum.reduce(org_ids, {0, MapSet.new()}, fn org_id, {racc, kacc} ->
        case pii_declared_keys(org_id, object_table, repo) do
          [] ->
            {racc, kacc}

          keys ->
            # jsonb `- text[]` removes every listed key from the bag; non-PII keys (and the
            # non-matching rows) are untouched.
            sql =
              "UPDATE #{record_table} SET #{bag_col} = COALESCE(#{bag_col}, '{}'::jsonb) - $1::text[] " <>
                "WHERE #{object_key_col}::text = $2 AND #{refs_col} ->> $3 = $4 AND #{org_col}::text = $5"

            %{num_rows: n} =
              Ecto.Adapters.SQL.query!(repo, sql, [keys, object_key, subject_ref_key, subject_id, org_id])

            {racc + n, Enum.reduce(keys, kacc, &MapSet.put(&2, &1))}
        end
      end)

    %{
      "resource" => label,
      "object_key" => object_key,
      "rows_redacted" => rows_redacted,
      "keys_redacted" => MapSet.size(keys_removed)
    }
  end

  # The org's `tnt_pii_declared: true` keys for this object — the SAME catalog the masking
  # resolver reads (`Samen.CustomFields.list_fields/3` keyed on the object's synthetic table).
  defp pii_declared_keys(org_id, object_table, repo) do
    org_id
    |> CustomFields.list_fields(object_table, repo)
    |> Enum.filter(& &1.tnt_pii_declared)
    |> Enum.map(& &1.tnt_field_name)
  end

  # A physical identifier must be a plain snake_case token. Hard gate, not sanitization
  # (mirrors `Samen.CustomFields.Erasure` / `Samen.NonPii` / `Samen.Auth.BlindIndexErasure`).
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in record_bag_erasure spec: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end
end
