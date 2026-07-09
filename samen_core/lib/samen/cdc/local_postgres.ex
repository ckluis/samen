defmodule Samen.Cdc.LocalPostgres do
  @moduledoc """
  A **faithful local simulation** of the ClickHouse CDC mirror (plan T6.5; plan
  HARD note "NO ClickHouse here — CDC gets faithful local simulations").

  This adapter mirrors the token-blind projection into a **second local Postgres
  schema** (`cdc_mirror` by default) standing in for the ClickHouse analytics tier.
  A distinct schema is the closest local analogue to "a second datastore, seconds-
  stale": it is a separate namespace the live-truth queries never touch, populated
  only through the CDC projection, never carrying a `pii_` plaintext column.

  ## What it proves (and what it doesn't)

  It PROVES, against a real database:

    * the projection materializes ONLY token/bounded-ID/enum/timestamp/number
      columns — the mirror table is created from `Samen.Cdc.Projection`, so a
      plaintext PII column can never physically appear (the projection excludes it,
      and `assert_no_plaintext!/1` raises if one tried);
    * post-shred the mirror holds only **dangling tokens** — the `vt_*` values are
      still in the mirror (append-only, seconds-stale), but the vault ciphertext
      they reference is undecryptable (key shredded), so the mirror scan finds
      nothing decryptable. Erasure was inherited for free.

  It does NOT simulate ClickHouse's columnar engine, MergeTree, or CDC lag — those
  are performance/consistency properties, not safety properties. The safety
  property (token-only-downstream) is what T6.5 must prove, and a Postgres schema
  proves it faithfully. The real engine is `Samen.Cdc.ClickHouse` (skeleton).

  ## Repo

  Uses `Samen.Cdc.Config.repo()` — in the local simulation this is the SAME
  physical Postgres server as the live repo, but everything is namespaced under the
  `cdc_mirror` schema so it is a distinct logical tier. (In production the repo is a
  separate `ecto_ch` connection — see `Samen.Cdc.ClickHouse`.)
  """

  @behaviour Samen.Cdc

  alias Samen.Cdc.Config
  alias Samen.Vault

  @impl Samen.Cdc
  def ensure_mirror(table, columns) do
    repo = repo!()
    schema = Config.schema()

    Ecto.Adapters.SQL.query!(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{schema}"), [])

    col_ddl =
      columns
      |> Enum.map(fn {name, kind} -> ~s("#{name}" #{sql_type(kind)}) end)
      |> Enum.join(", ")

    # A mirror row also carries the subject_id so the oracle can scan per-subject.
    # subject_id is a bounded/opaque id (never a name) — same class as tenant_id.
    Ecto.Adapters.SQL.query!(
      repo,
      ~s|CREATE TABLE IF NOT EXISTS "#{schema}"."#{table}" (cdc_subject_id text#{maybe_comma(col_ddl)}#{col_ddl})|,
      []
    )

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl Samen.Cdc
  def mirror_row(table, columns, values, _opts) do
    repo = repo!()
    schema = Config.schema()

    col_names = ["cdc_subject_id" | Enum.map(columns, &elem(&1, 0))]

    row_values = [
      Map.get(values, "cdc_subject_id") || Map.get(values, :cdc_subject_id)
      | Enum.map(columns, fn {name, _kind} -> Map.get(values, name) end)
    ]

    placeholders =
      1..length(col_names) |> Enum.map(&"$#{&1}") |> Enum.join(", ")

    cols_sql = col_names |> Enum.map(&~s("#{&1}")) |> Enum.join(", ")

    Ecto.Adapters.SQL.query!(
      repo,
      ~s|INSERT INTO "#{schema}"."#{table}" (#{cols_sql}) VALUES (#{placeholders})|,
      row_values
    )

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl Samen.Cdc
  def mirrored_columns(table, _opts) do
    repo = repo!()
    schema = Config.schema()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = $2",
        [schema, table]
      )

    {:ok, rows |> List.flatten() |> Enum.map(&to_string/1)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl Samen.Cdc
  def scan_no_plaintext(subject_id, _opts) do
    repo = repo!()
    schema = Config.schema()

    # For EVERY mirror table, collect every `vt_*` token value for the subject and
    # try to reveal it. A token-blind mirror answers no_plaintext because the vault
    # ciphertext is (post-shred) undecryptable. If the mirror ever grew a real
    # plaintext PII column, `mirrored_columns` + the projection would have refused
    # it — but we ALSO scan token values here so the oracle proves the concrete
    # rows, not just the schema shape.
    tokens = mirror_tokens_for(repo, schema, subject_id)

    leaks =
      tokens
      |> Enum.filter(fn token -> decryptable?(token, repo) end)
      |> Enum.map(fn token -> "mirror token #{token} still decrypts" end)

    if leaks == [], do: {:ok, :no_plaintext}, else: {:leaks, leaks}
  rescue
    e -> {:leaks, ["cdc mirror scan failed: #{Exception.message(e)}"]}
  end

  @impl Samen.Cdc
  def read_current(table, key, _opts) do
    raise Samen.Cdc.NeverReadCurrent.Violation,
      message:
        "read_current/3 called on the CDC analytics mirror (table=#{inspect(table)}, " <>
          "key=#{inspect(key)}). The analytics tier is seconds-stale by construction — you " <>
          "NEVER read a 'current' value from it (doc line 635). Read live truth from the " <>
          "primary Postgres repo instead."
  end

  # ---------------------------------------------------------------------------

  @doc """
  Every `vt_*` token stored anywhere in the mirror schema for `subject_id`.

  Public so the oracle tier can report the dangling-token count (post-shred the
  mirror still holds these tokens — that is the whole point: they are dangling,
  the ciphertext they point at is gone).
  """
  @spec dangling_tokens(String.t()) :: [String.t()]
  def dangling_tokens(subject_id) do
    mirror_tokens_for(repo!(), Config.schema(), subject_id)
  end

  defp mirror_tokens_for(repo, schema, subject_id) do
    %{rows: tables} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1",
        [schema]
      )

    tables
    |> List.flatten()
    |> Enum.flat_map(fn table -> token_values(repo, schema, to_string(table), subject_id) end)
    |> Enum.uniq()
  end

  # Gather every text-column value that looks like a vault token (`vt_*`) for the
  # subject. A mirror carries tokens, not names — so this is the full plaintext-
  # reachable surface the oracle must clear.
  defp token_values(repo, schema, table, subject_id) do
    %{rows: col_rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = $2 AND data_type IN ('text','character varying')",
        [schema, table]
      )

    text_cols = col_rows |> List.flatten() |> Enum.map(&to_string/1)

    text_cols
    |> Enum.flat_map(fn col ->
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          ~s(SELECT "#{col}" FROM "#{schema}"."#{table}" WHERE cdc_subject_id = $1),
          [subject_id]
        )

      rows
      |> List.flatten()
      |> Enum.filter(fn v -> is_binary(v) and String.starts_with?(v, "vt_") end)
    end)
  end

  defp decryptable?(token, repo) do
    match?({:ok, _}, Vault.reveal(%Samen.Masked{token: token, label: "cdc"}, repo))
  rescue
    _ -> false
  end

  defp repo! do
    Config.repo() ||
      raise "Samen.Cdc.LocalPostgres requires a repo — wire config :samen_core, :cdc, repo: MyRepo"
  end

  defp sql_type(:token), do: "text"
  defp sql_type(:bounded_id), do: "text"
  defp sql_type(:enum), do: "text"
  defp sql_type(:timestamp), do: "timestamptz"
  defp sql_type(:number), do: "numeric"
  # A boolean mirrors as text: the CDC feed carries values as strings ("true"/
  # "false"), matching how the token-blind row is projected. (ADR-015 gave boolean
  # its own projection kind so it is no longer swept into the :metadata fall-through.)
  defp sql_type(:boolean), do: "text"
  defp sql_type(:metadata), do: "text"

  defp maybe_comma(""), do: ""
  defp maybe_comma(_), do: ", "
end
