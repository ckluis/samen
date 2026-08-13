defmodule Samen.OperatorPlane.Migration do
  @moduledoc """
  Shared migration helpers for the operator-plane control-plane tables (T6.1
  extraction; ADR-005).

  ## Why this exists — the copy-paste the extraction retro found

  Before this module, EVERY host that mounts the operator plane (`samen_core`'s
  own test repo, `demo`, and the `driftwood` reference vertical) carried a
  **byte-identical** `aud_chain` migration — the same `CREATE TABLE aud_chain`,
  the same UNIQUE `(ach_org_id, ach_seq)` index, the same append-only trigger +
  function, the same `REVOKE UPDATE, DELETE`, and the same 15 `tam_table`/
  `fld_field` catalog rows — differing only in the module name and the `otp_app`
  atom used to read `:aud_event_app_role`. Three copies of one load-bearing,
  security-critical table (the tamper-evident audit chain) is exactly the
  Rule-of-Three signal that the shape belongs in the core: a bug fix or a column
  add to the chain had to be applied in three places and could silently drift.

  See ADR-002 for the chain design and ADR-005 for the extraction decision.

  ## What the host still owns

  The host owns the migration *module* (its name, its file, its position in the
  migration order) and its `otp_app` — because `aud_chain`'s append-only
  `REVOKE`/`GRANT` must name the host's Postgres role, and the migration DDL +
  the same-transaction catalog INSERTs must execute in the **host's** repo's
  migration transaction (the S0.4 / `Samen.Migration` invariant). This module
  emits the *body*; the host wraps it:

      defmodule MyApp.Repo.Migrations.AudChain do
        use Ecto.Migration

        # ADR-045 §4.2 (O4): DERIVE the app role at migration time (knob → repo :username →
        # RAISE) via the shared helper — NEVER a hardcoded developer laptop role ("clank").
        defp app_role, do: Samen.OperatorPlane.Migration.app_role!(:my_app, MyApp.Repo)

        def up,   do: Samen.OperatorPlane.Migration.create_aud_chain(app_role())
        def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(app_role())
      end

  The DDL body, the column list, the catalog rows, and the append-only
  enforcement are now defined ONCE, here, and shared verbatim by every host.

  ## Column list is derived, not re-typed

  The `aud_chain` column list is derived from `Samen.OperatorPlane.Migration`'s
  single `@aud_chain_fields` — the same 15 `ach_` columns backing the
  `Samen.AuditChain.Entry` schema. A drift between the DDL and the schema is
  caught by the host's `catalog_parity` verifier (the catalog rows this emits
  are diffed against `Samen.Catalog` introspection of the resources), so this
  module cannot silently emit a wrong column set without failing a host's CI.

  ## Plain Ecto DDL, not `Samen.Migration`

  Like the `aud_event` tier, `aud_chain` is kernel infra backed by a plain
  `Ecto.Schema` (`Samen.AuditChain.Entry`), not a `Samen.Resource`. So the
  catalog rows are written via direct `execute/2` in the same transaction (the
  same reason the original three copies used `use Ecto.Migration`, not
  `use Samen.Migration`). The host's migration MUST run inside a DDL transaction
  (do NOT set `@disable_ddl_transaction true`) so the catalog rows and the table
  commit or abort together — the fail-closed guarantee.
  """

  @table "aud_chain"
  @resource "Samen.AuditChain.Entry"

  # The 15 `ach_` columns — {physical_column, logical_name, catalog_type}.
  # This is the ONE definition; before the extraction it was duplicated in three
  # migration files. Order is the DDL order (down/0 reverses it for catalog rows).
  @aud_chain_fields [
    {"ach_id", "id", "UUID"},
    {"ach_org_id", "org_id", "String"},
    {"ach_seq", "seq", "Integer"},
    {"ach_prior_hash", "prior_hash", "String"},
    {"ach_hash", "hash", "String"},
    {"ach_aud_id", "aud_id", "UUID"},
    {"ach_event_type", "event_type", "String"},
    {"ach_subject_id", "subject_id", "String"},
    {"ach_actor_id", "actor_id", "String"},
    {"ach_correlation_id", "correlation_id", "String"},
    {"ach_detail", "detail", "String"},
    {"ach_occurred_at", "occurred_at", "UTCDatetime"},
    {"ach_ciphertext_sha256", "ciphertext_sha256", "String"},
    {"ach_subject_ciphertext", "subject_ciphertext", "Binary"},
    {"ach_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  @doc "The `aud_chain` table name (`\"aud_chain\"`)."
  @spec table() :: String.t()
  def table, do: @table

  @doc """
  The `aud_chain` catalog field list — `[{physical_col, logical_name, type}]`.
  Exposed so a test (or a host) can assert the DDL and the catalog agree with the
  `Samen.AuditChain.Entry` schema without re-typing the list.
  """
  @spec aud_chain_fields() :: [{String.t(), String.t(), String.t()}]
  def aud_chain_fields, do: @aud_chain_fields

  @doc """
  Emit the FULL `aud_chain` up-migration into the CURRENT migration transaction:
  the table, the dense per-org sequence UNIQUE index, the tip-lookup index, the
  append-only trigger + function, the `REVOKE UPDATE, DELETE` from `app_role`,
  and the same-transaction `tam_table`/`fld_field` catalog rows.

  Call from a host migration's `up/0`. `app_role` is the host's Postgres role
  (the one `:aud_event_app_role` config names). Every `execute/2` ships a reverse
  clause, so a host that calls this from `change/0` also gets a working rollback;
  hosts that split `up/0`/`down/0` should call `drop_aud_chain/1` in `down/0`.

  Requires `import Ecto.Migration` in scope (a host migration `use Ecto.Migration`
  provides it). Raises a clear error if `app_role` is not a plain identifier — an
  interpolated role name is a (developer-controlled) SQL-injection surface we hard
  gate anyway.
  """
  @spec create_aud_chain(String.t()) :: :ok
  def create_aud_chain(app_role) when is_binary(app_role) do
    role = safe_role!(app_role)

    exec2(
      """
      CREATE TABLE aud_chain (
        ach_id                  UUID        NOT NULL DEFAULT gen_random_uuid(),
        ach_org_id              TEXT        NOT NULL,
        ach_seq                 BIGINT      NOT NULL,
        ach_prior_hash          TEXT        NOT NULL,
        ach_hash                TEXT        NOT NULL,
        ach_aud_id              UUID,
        ach_event_type          TEXT        NOT NULL,
        ach_subject_id          TEXT,
        ach_actor_id            TEXT,
        ach_correlation_id      TEXT,
        ach_detail              TEXT,
        ach_occurred_at         TIMESTAMPTZ NOT NULL,
        ach_ciphertext_sha256   TEXT        NOT NULL,
        ach_subject_ciphertext  BYTEA,
        ach_inserted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (ach_id)
      )
      """,
      "DROP TABLE IF EXISTS aud_chain"
    )

    exec2(
      "CREATE UNIQUE INDEX aud_chain_org_seq_uidx ON aud_chain (ach_org_id, ach_seq)",
      "DROP INDEX IF EXISTS aud_chain_org_seq_uidx"
    )

    exec2(
      "CREATE INDEX aud_chain_org_seq_desc_idx ON aud_chain (ach_org_id, ach_seq DESC)",
      "DROP INDEX IF EXISTS aud_chain_org_seq_desc_idx"
    )

    exec2(
      """
      CREATE OR REPLACE FUNCTION aud_chain_enforce_append_only()
      RETURNS TRIGGER LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'aud_chain is append-only: UPDATE and DELETE are not permitted. '
          'Chain entry id: %, org: %, seq: %',
          COALESCE(OLD.ach_id::text, '?'),
          COALESCE(OLD.ach_org_id, '?'),
          COALESCE(OLD.ach_seq::text, '?');
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS aud_chain_enforce_append_only()"
    )

    exec2(
      """
      CREATE TRIGGER aud_chain_append_only_tg
      BEFORE UPDATE OR DELETE ON aud_chain
      FOR EACH ROW EXECUTE FUNCTION aud_chain_enforce_append_only()
      """,
      "DROP TRIGGER IF EXISTS aud_chain_append_only_tg ON aud_chain"
    )

    exec2(
      "REVOKE UPDATE, DELETE ON aud_chain FROM #{role}",
      "GRANT UPDATE, DELETE ON aud_chain TO #{role}"
    )

    exec2(
      """
      INSERT INTO tam_table (tam_table_name, tam_resource)
      VALUES ('#{@table}', '#{@resource}')
      ON CONFLICT (tam_table_name) DO NOTHING
      """,
      "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"
    )

    for {col, logical, type} <- @aud_chain_fields do
      exec2(
        """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('#{@table}', '#{col}', '#{logical}', '#{type}')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """,
        """
        DELETE FROM fld_field
        WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
        """
      )
    end

    :ok
  end

  @doc """
  Emit the FULL `aud_chain` down-migration (the inverse of `create_aud_chain/1`)
  into the current migration transaction: delete the catalog rows (reverse order),
  the `tam_table` row, re-`GRANT` the role, drop the trigger/function/indexes/table.

  Call from a host migration's `down/0`. `app_role` must match the one passed to
  `create_aud_chain/1`.
  """
  @spec drop_aud_chain(String.t()) :: :ok
  def drop_aud_chain(app_role) when is_binary(app_role) do
    role = safe_role!(app_role)

    for {col, _logical, _type} <- Enum.reverse(@aud_chain_fields) do
      exec1(
        "DELETE FROM fld_field WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'"
      )
    end

    exec1("DELETE FROM tam_table WHERE tam_table_name = '#{@table}'")
    exec1("GRANT UPDATE, DELETE ON aud_chain TO #{role}")
    exec1("DROP TRIGGER IF EXISTS aud_chain_append_only_tg ON aud_chain")
    exec1("DROP FUNCTION IF EXISTS aud_chain_enforce_append_only()")
    exec1("DROP INDEX IF EXISTS aud_chain_org_seq_desc_idx")
    exec1("DROP INDEX IF EXISTS aud_chain_org_seq_uidx")
    exec1("DROP TABLE IF EXISTS aud_chain")

    :ok
  end

  @doc """
  Resolve the Postgres app role for the `aud_event`/`aud_chain` `REVOKE UPDATE, DELETE`
  grant AT MIGRATION TIME (ADR-045 §4.2, O4) — the SHARED derivation both the generated
  `m_aud_event.eex` template and every in-repo host migration (driftwood/pawchart/demo)
  use, so a role is NEVER a hardcoded developer laptop role (`"clank"`) shipped into an
  adopter's prod migration (whose first `release_command` would then abort with
  `role "clank" does not exist`).

  Resolution order:

    1. the explicit `:aud_event_app_role` knob (what a real prod deploy sets — the deploy
       runbook's Operator TODO), else
    2. the repo's CONFIGURED `:username` (the role this app actually connects as in dev/CI),
       else
    3. RAISE a named error — refusing to guess a role, since a `REVOKE` against the WRONG
       role silently leaves the audit tables mutable for the real app role (an
       audit-integrity gap), which is worse than a loud failure.

  `otp_app` is the host's OTP app atom; `repo` is the host's `Ecto.Repo` module (the key its
  `:username` is configured under). The returned role is NOT `safe_role!/1`-checked here —
  `create_aud_chain/1`/`drop_aud_chain/1` (and the template's own DDL) apply that gate at the
  interpolation site.
  """
  @spec app_role!(atom(), module()) :: String.t()
  def app_role!(otp_app, repo) when is_atom(otp_app) and is_atom(repo) do
    case Application.get_env(otp_app, :aud_event_app_role) do
      role when is_binary(role) and role != "" ->
        role

      _ ->
        repo_username =
          otp_app
          |> Application.get_env(repo, [])
          |> Keyword.get(:username)

        case repo_username do
          role when is_binary(role) and role != "" ->
            role

          _ ->
            raise """
            #{inspect(repo)}: cannot determine the Postgres app role for the audit-table
            REVOKE UPDATE, DELETE grant (ADR-045 §4.2, O4).

            Set it explicitly (the deploy runbook's `aud_event_app_role` step):

                config #{inspect(otp_app)}, :aud_event_app_role, "your_app_db_role"

            It could not be derived from the repo's configured :username either. Refusing to
            emit an arbitrary role — a REVOKE against the wrong role would silently leave the
            audit tables mutable for the real app role (an audit-integrity gap).
            """
        end
    end
  end

  # `Ecto.Migration.execute/1,2` depends on the migration process's runtime state
  # and is normally used via `import Ecto.Migration` inside a migration module.
  # A host migration that calls `create_aud_chain/1`/`drop_aud_chain/1` already has
  # the migration runtime active, so we delegate straight to it. We call it via
  # `apply/3` so this plain module (no `use Ecto.Migration`) compiles cleanly.
  defp exec2(up_sql, down_sql), do: apply(Ecto.Migration, :execute, [up_sql, down_sql])
  defp exec1(sql), do: apply(Ecto.Migration, :execute, [sql])

  # A Postgres role name is a developer-controlled identifier, never user input,
  # but it is interpolated into REVOKE/GRANT DDL — so we hard-gate it to a plain
  # identifier (letters, digits, underscore; optionally double-quoted) and refuse
  # anything else. Fail closed: an odd role name aborts the migration rather than
  # emitting injectable DDL.
  defp safe_role!(role) do
    if Regex.match?(~r/\A"?[a-zA-Z_][a-zA-Z0-9_]*"?\z/, role) do
      role
    else
      raise ArgumentError,
            "unsafe Postgres role name for aud_chain REVOKE/GRANT: #{inspect(role)} " <>
              "(must match /^\"?[a-zA-Z_][a-zA-Z0-9_]*\"?$/). The role is interpolated " <>
              "into DDL; refusing to emit an injectable migration."
    end
  end
end
