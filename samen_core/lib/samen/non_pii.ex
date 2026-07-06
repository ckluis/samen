defmodule Samen.NonPii do
  @moduledoc """
  The `non_pii!` registry (doc D8; §limits carve-out (b); T1.7 (b)).

  A `non_pii!` exception is a **review-gated** declaration that a specific
  physical column is plaintext-at-rest by design. Two reviewers must agree
  (`cleared_by` != `reviewed_by`) — the same distinct-party discipline the reveal
  grant uses. This module is the **registry**: it records the accepted override
  (with who/why metadata) and exposes the erasure recipe. The *enforcement UX*
  — failing the build until a flagged plain column has an entry — is the T1.8c
  `pii_classify` verifier, out of scope here.

  ## What this module owns (T1.7 scope)

    * `register/1` — record a review-gated override. Refuses self-review
      (`cleared_by == reviewed_by`) — fail closed, the same distinct-party rule as
      reveal grants (defence against a single actor waving a plaintext column
      through). Idempotent per `(table, column)`.
    * `entries/1`, `catalog_flags/1` — the registry read side the catalog and the
      oracle consume.
    * `redact_for_subject/3` — the **erasure arm**: row-level redaction of every
      registered plaintext column for a subject, writing the recipe's redaction
      sentinel over the plaintext value. Returns the count redacted. Called only
      by `Samen.Erasure`.

  ## Why redaction, not key-shred (D8)

  Key-shred destroys the subject DEK, which makes every *vaulted* value
  undecryptable at once. A `non_pii!` column is NOT vaulted — it is plaintext —
  so key-shred does not touch it. The limits name it explicitly as a carve-out
  key-shred does not reach. Erasure must therefore reach it directly, by
  overwriting the plaintext with a non-reversible sentinel (row-level redaction),
  and record that it ran so the oracle's `registered_non_pii` tier can assert it.
  """

  alias Samen.NonPii.Entry

  import Ecto.Query, only: [from: 2]

  @doc """
  The configured repo backing the registry. Configure via `:non_pii_repo`, or
  fall back to `:reveal_grant_repo` / `:verify_repo` so a host app only sets one.
  """
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :verify_repo) ||
      raise """
      Samen.NonPii needs a repo. Configure it:

          config :samen_core, :non_pii_repo, MyApp.Repo
      """
  end

  @doc """
  Register a review-gated `non_pii!` override.

  Required keys:
    * `:table_name`  — the physical (abbrev-prefixed) table
    * `:column_name` — the physical column cleared as non-PII
    * `:cleared_by`  — who requested the exception
    * `:reviewed_by` — the DISTINCT 2nd reviewer who signed off
    * `:reason`      — why this column is plaintext-at-rest by design
    * `:subject_column` — the column carrying the subject id (for the erasure arm)

  Optional:
    * `:redaction` — the sentinel written on erasure (default `"[REDACTED]"`)
    * `:repo`      — override the configured repo

  Fails closed with `{:error, :self_review}` if `cleared_by == reviewed_by`:
  a single actor cannot wave a plaintext column through. This is the registry's
  distinct-party invariant (the build-time enforcement is T1.8c).

  Idempotent per `(table_name, column_name)` — re-registering updates the row.
  """
  @spec register(map()) :: {:ok, Entry.t()} | {:error, term}
  def register(attrs) do
    r = Map.get(attrs, :repo, repo())

    cleared_by = fetch!(attrs, :cleared_by)
    reviewed_by = fetch!(attrs, :reviewed_by)

    if cleared_by == reviewed_by do
      {:error, :self_review}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      params = %{
        table_name: to_string(fetch!(attrs, :table_name)),
        column_name: to_string(fetch!(attrs, :column_name)),
        cleared_by: cleared_by,
        reviewed_by: reviewed_by,
        reason: fetch!(attrs, :reason),
        subject_column: to_string(fetch!(attrs, :subject_column)),
        redaction: Map.get(attrs, :redaction, "[REDACTED]"),
        registered_at: now
      }

      %Entry{}
      |> Ecto.Changeset.cast(params, [
        :table_name,
        :column_name,
        :cleared_by,
        :reviewed_by,
        :reason,
        :subject_column,
        :redaction,
        :registered_at
      ])
      |> Ecto.Changeset.validate_required([
        :table_name,
        :column_name,
        :cleared_by,
        :reviewed_by,
        :reason,
        :subject_column
      ])
      |> r.insert(
        on_conflict: {:replace, [:cleared_by, :reviewed_by, :reason, :subject_column, :redaction]},
        conflict_target: [:table_name, :column_name]
      )
    end
  end

  @doc "All registered `non_pii!` overrides (the registry, read side)."
  @spec entries(keyword()) :: [Entry.t()]
  def entries(opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    r.all(from(e in Entry, order_by: [asc: e.table_name, asc: e.column_name]))
  end

  @doc """
  The catalog flags for the registered overrides (D8: "registered in the
  catalog"). Returns `{table, column} => %{cleared_by, reviewed_by, reason}` —
  the flag + who/why metadata the `fld_field` catalog surface carries.
  """
  @spec catalog_flags(keyword()) :: %{{String.t(), String.t()} => map()}
  def catalog_flags(opts \\ []) do
    entries(opts)
    |> Map.new(fn e ->
      {{e.table_name, e.column_name},
       %{cleared_by: e.cleared_by, reviewed_by: e.reviewed_by, reason: e.reason}}
    end)
  end

  @doc """
  **The erasure arm (T1.7 (c)).** Redact every registered `non_pii!` plaintext
  column for `subject_id`, writing the recipe's redaction sentinel over the
  plaintext value where the row's `subject_column` matches.

  Returns `{:ok, count, details}` where `count` is the total number of *cells*
  redacted and `details` is a per-column tally the erasure report records.

  Idempotent: a second call redacts rows again where the value is not already the
  sentinel (0 additional on the second pass). Only ever called by `Samen.Erasure`.

  SECURITY NOTE: `table_name`/`column_name`/`subject_column` come from the
  registry, which is populated only by `register/1` from developer-controlled
  identifiers (never end-user input). They are still validated as safe SQL
  identifiers before interpolation, and the redaction + subject values are passed
  as bound parameters.
  """
  @spec redact_for_subject(String.t(), module(), keyword()) ::
          {:ok, non_neg_integer(), [map()]}
  def redact_for_subject(subject_id, r, opts \\ []) do
    only_entries = Keyword.get(opts, :entries) || entries(repo: r)

    {total, details} =
      Enum.reduce(only_entries, {0, []}, fn %Entry{} = e, {acc, det} ->
        n = redact_one(subject_id, e, r)

        {acc + n,
         [
           # String keys: this rides into the JSON `era_tiers` column of the
           # erasure report, so it must be JSON-consistent whether the oracle
           # reads it from the returned struct or re-reads it from Postgres.
           %{
             "table" => e.table_name,
             "column" => e.column_name,
             "redacted" => n
           }
           | det
         ]}
      end)

    {:ok, total, Enum.reverse(details)}
  end

  @doc """
  Oracle probe (T2.9, DB-tier check for the `registered_non_pii` tier): does any
  registered `non_pii!` column STILL hold a non-redacted value for `subject_id`?

  The `registered_non_pii` tier asserts row-level redaction actually ran. This
  returns the list of columns where a row for the subject still carries a value
  DISTINCT from the recipe's redaction sentinel (i.e. plaintext survived erasure)
  — each entry is a violation the oracle fails on. An empty list means every
  registered column for the subject is redacted (or has no rows), the expected
  post-shred state.

  Uses the SAME identifier-hardening (`safe_ident!`) and bound parameters as the
  redaction arm — the table/column/subject-column come from the registry, never
  end-user input.
  """
  @spec unredacted_columns_for_subject(String.t(), module(), keyword()) :: [map()]
  def unredacted_columns_for_subject(subject_id, r, opts \\ []) do
    only_entries = Keyword.get(opts, :entries) || entries(repo: r)

    Enum.flat_map(only_entries, fn %Entry{} = e ->
      case count_unredacted(subject_id, e, r) do
        :error ->
          [
            %{
              "table" => e.table_name,
              "column" => e.column_name,
              "unredacted" => "introspection_failed"
            }
          ]

        count when count > 0 ->
          [%{"table" => e.table_name, "column" => e.column_name, "unredacted" => count}]

        _zero ->
          []
      end
    end)
  end

  defp count_unredacted(subject_id, %Entry{} = e, r) do
    table = safe_ident!(e.table_name)
    column = safe_ident!(e.column_name)
    subject_column = safe_ident!(e.subject_column)

    sql =
      "SELECT count(*) FROM #{table} " <>
        "WHERE #{subject_column} = $2 AND (#{column} IS DISTINCT FROM $1) AND #{column} IS NOT NULL"

    %{rows: [[n]]} = Ecto.Adapters.SQL.query!(r, sql, [e.redaction, subject_id])
    n
  rescue
    # A registry entry naming a table/column that does not exist in this repo is a
    # fail-closed condition for the oracle, surfaced as a large sentinel count.
    _ -> :error
  end

  # Redact a single registered column for a subject. Uses a parameterized UPDATE:
  # identifiers validated, values bound.
  defp redact_one(subject_id, %Entry{} = e, r) do
    table = safe_ident!(e.table_name)
    column = safe_ident!(e.column_name)
    subject_column = safe_ident!(e.subject_column)

    sql =
      "UPDATE #{table} SET #{column} = $1 " <>
        "WHERE #{subject_column} = $2 AND (#{column} IS DISTINCT FROM $1)"

    %{num_rows: n} = Ecto.Adapters.SQL.query!(r, sql, [e.redaction, subject_id])
    n
  end

  # A physical identifier must be a plain snake_case token. This is a hard gate,
  # not sanitization — anything with a quote/space/paren/semicolon is refused.
  defp safe_ident!(name) do
    str = to_string(name)

    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, str) do
      str
    else
      raise ArgumentError,
            "unsafe SQL identifier in non_pii! registry: #{inspect(str)} " <>
              "(identifiers must match /^[a-z_][a-z0-9_]*$/)"
    end
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end
end
