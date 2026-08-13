defmodule Samen.Web.Csv.Report do
  @moduledoc """
  The per-row import error report (WS-E E3.3; ADR-028; AC-G15-3/5). Import is
  fail-closed PER ROW: a row that fails its governed create is recorded here and
  written nowhere — the report is the honest account of what was and wasn't imported.
  """
  defstruct total: 0, created: 0, errors: []

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          created: non_neg_integer(),
          # [%{row: 1-based CSV data-row number, error: String.t()}]
          errors: list(map())
        }
end

defmodule Samen.Web.Csv do
  @moduledoc """
  Catalog-driven CSV export/import for ANY mounted resource (WS-E E3; ADR-028) —
  ONE framework module, zero per-vertical CSV code (AC-G15-1).

  ## Export is a first-class MASKING surface (AC-G15-2, NON-NEGOTIABLE)

  Every page of records is resolved through `Samen.Api.PiiResolution` on the acting
  scope's plane BEFORE any cell is serialized — the CSV cell and the pixel show the
  SAME value on the same plane:

    * tenant own-org           → plaintext (the tenant owns its customers' PII);
    * operator (impersonation) → `%Samen.Masked{}` → the cell is `••••` — NEVER the
      plaintext, NEVER a `vt_*` vault token;
    * operator API-key posture → `%Ash.ForbiddenField{}` → the cell is EMPTY
      (mask-by-omission, the field is absent).

  This module never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, and
  has no raw-row read path — export cannot leak what the UI wouldn't show.

  ## Export is BOUNDED (AC-G15-4)

  Rows are read exclusively via `Samen.Web.Reads.page!/3` keyset iteration (sorted
  `{:id, :asc}`, clamped page size, cursor-chained until `has_more` is false). There
  is no `Ash.read!` of the full set anywhere in this module.

  ## Import routes through the GOVERNED chokepoint (AC-G15-3)

  `import/3` sends each row through the resource's governed create action
  (`WriteGuard` + `Vault.Change` — the same action the UI forms call), under the
  caller's scope. Bulk import is NOT a new PII-write trust surface: a tenant import
  vault-routes PII (`vt_*` at rest, plaintext nowhere); an operator import is refused
  row-by-row by the same policies that refuse the form. There is no `insert_all`.

  ## Import is fail-closed on bad mapping (AC-G15-5)

  A header column that is not an importable public attribute — anything mapped to
  `id`, `org_id`, timestamps, or an unknown/private name — rejects the WHOLE file
  with `{:error, {:bad_mapping, columns}}` before a single row is written.

  ## CSV format (ship note: hand-rolled RFC 4180, no new dependency)

  Serialization and parsing implement RFC 4180 directly (quoting, embedded quotes/
  commas/newlines, CRLF row endings) — ~40 lines, no parser dependency to audit.
  Composite values (`Samen.Type.FullName` etc.) serialize as JSON objects; import
  cells that parse as JSON objects/arrays are decoded before the governed cast.
  """

  alias Samen.Web.Csv.Report
  alias Samen.Web.ListState
  alias Samen.Web.Reads

  @mask "••••"

  # CSV formula-injection lead characters (WS-F1 / F1.4, OWASP "CSV Injection"): a cell
  # whose FIRST character is one of these is one a spreadsheet may evaluate as a formula
  # (`= + - @`) or use to shift the payload into an adjacent cell (a leading TAB/CR).
  @formula_leads [?=, ?+, ?-, ?@, ?\t, ?\r]

  # Columns that may NEVER be exported as data or mapped by an import (AC-G15-5):
  # identity/tenancy/bookkeeping are the system's, not the CSV's.
  @forbidden_columns [:id, :org_id, :inserted_at, :updated_at]

  @doc "The identity/tenancy/bookkeeping columns CSV never carries."
  def forbidden_columns, do: @forbidden_columns

  @doc """
  Resolve a route's `:resource` name onto the mount's namespace, DENY-BY-DEFAULT
  (WS-E E3.4): the (camelized) name must resolve — without minting atoms — to a
  module that is a registered resource of the mount's DOMAIN. Anything else is
  `{:error, :unknown_resource}` — the CSV routes can only ever serve what the
  host explicitly mounted.
  """
  def resolve_resource(%Samen.Web.Mount{} = mount, name) when is_binary(name) do
    resource =
      try do
        Samen.Web.Mount.resource(mount, String.to_existing_atom(Macro.camelize(name)))
      rescue
        ArgumentError -> nil
      end

    if resource != nil and resource in Ash.Domain.Info.resources(mount.domain) do
      {:ok, resource}
    else
      {:error, :unknown_resource}
    end
  end

  def resolve_resource(_mount, _name), do: {:error, :unknown_resource}

  @doc """
  The DEFAULT export/import column set for `resource` — its PUBLIC attributes
  (logical names, from the same `Ash.Resource.Info` truth the catalog is generated
  from) minus `forbidden_columns/0`. Deny-by-default: private attributes never
  appear, and an explicit `:columns` request is validated against this set.
  """
  def columns(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in @forbidden_columns))
    |> Enum.sort()
  end

  @doc """
  Export `resource` rows for `scope` as an RFC-4180 CSV binary — `{:ok, csv}` or
  `{:error, {:unknown_columns, cols}}`.

  Options:

    * `:repo`      — REQUIRED. The vault repo for `PiiResolution` (masking would
      otherwise fail closed to `••••` on every plane — safe, but not the tenant's
      own data).
    * `:columns`   — optional allowlist SUBSET of `columns/1` (unknown/forbidden
      names are rejected, never silently dropped).
    * `:page_size` — keyset page size (clamped by `Reads`; default `#{Reads.default_page_size()}`).
    * `:query`     — optional pre-scoped `Ash.Query` base (defaults to `resource`).
  """
  def export(resource, scope, opts \\ []) do
    with {:ok, cols} <- validate_columns(resource, Keyword.get(opts, :columns)) do
      page_size = Keyword.get(opts, :page_size, Reads.default_page_size())
      base = Keyword.get(opts, :query, resource)

      rows = export_rows(base, resource, scope, cols, page_size, opts, nil, [])
      # WS-F5 F5.2 — row-count histogram sample through the bounded Samen.Metrics
      # machinery (`samen.csv.export.row_count`). The count is a measurement; the only
      # tag is the bounded `:result`. Best-effort — never fails an export.
      emit_export_telemetry(length(rows))
      {:ok, serialize([Enum.map(cols, &to_string/1) | rows])}
    end
  end

  defp emit_export_telemetry(row_count) do
    :telemetry.execute([:samen, :csv, :export, :stop], %{row_count: row_count}, %{result: :ok})
  rescue
    _ -> :ok
  end

  @doc """
  Import the CSV binary in `opts[:csv]` into `resource` for `scope`, one governed
  create per data row — `{:ok, %Report{}}`, or `{:error, {:bad_mapping, cols}}` /
  `{:error, :empty}` before anything is written.

  Options:

    * `:csv`    — REQUIRED. The raw CSV binary (header row + data rows).
    * `:action` — the governed create action (default `:create`).
  """
  def import(resource, scope, opts \\ []) do
    csv = Keyword.fetch!(opts, :csv)
    action = Keyword.get(opts, :action, :create)

    with {:ok, header, rows} <- parse_with_header(csv),
         {:ok, cols} <- validate_mapping(resource, header) do
      %Report{} =
        report =
        rows
        |> Enum.with_index(1)
        |> Enum.reduce(%Report{total: length(rows)}, fn {row, n}, acc ->
          import_row(resource, action, scope, cols, row, n, acc)
        end)

      {:ok, %Report{report | errors: Enum.reverse(report.errors)}}
    end
  end

  @doc """
  Read ONE keyset page of export rows — the ONLY read path export uses (AC-G15-4;
  the RP-CSV-3 bounded-read probe exercises this seam directly via
  `Samen.Web.Reads.bounded!/4`). Funnels through `Reads.page!/3`: keyset-sorted,
  cursor-chained, page size clamped — unbounded by construction impossible.
  """
  def page(base, scope, %ListState{} = state, cols \\ []) do
    base
    |> Ash.Query.ensure_selected(cols)
    |> Reads.page!(state, scope: scope)
  end

  # -- export internals --------------------------------------------------------

  # Keyset-iterate pages via page/4 → Reads.page!/3 (AC-G15-4) and resolve every
  # page through PiiResolution BEFORE serialization (AC-G15-2).
  defp export_rows(base, resource, scope, cols, page_size, opts, cursor, acc) do
    state = %ListState{page_size: page_size, sort: {:id, :asc}, cursor: cursor}

    page = page(base, scope, state, cols)

    resolved =
      Samen.Api.PiiResolution.resolve(
        page.items,
        resource,
        actor_of(scope),
        repo: Keyword.fetch!(opts, :repo)
      )

    row_values =
      Enum.map(resolved, fn record ->
        Enum.map(cols, fn col -> cell_for_column(Map.get(record, col), resource, col) end)
      end)

    acc = acc ++ row_values

    if page.has_more do
      export_rows(base, resource, scope, cols, page_size, opts, page.next_cursor, acc)
    else
      acc
    end
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp scope_org_id(scope), do: scope |> actor_of() |> Map.get(:org_id)

  # Cell serialization — the plane-resolved value, faithfully:
  #   %Masked{}         → "••••"  (present-but-masked, the impersonation UI value)
  #   %Ash.ForbiddenField{} → ""  (absent — the operator API-key mask-by-omission)
  # Never a vt_* token: a %Masked{} stringifies to the mask, and this module never
  # touches the at-rest column.
  defp cell(nil), do: ""
  defp cell(%Samen.Masked{}), do: @mask
  defp cell(%Ash.ForbiddenField{}), do: ""
  # ADR-036 D5/H7 (Money row): the canonical CSV cell is ISO-4217 "CUR 12.34" —
  # a currency code, a space, and the plain decimal amount (no thousands grouping,
  # so `decode_cell/1` → the governed action's `cast_input` parses it losslessly
  # via AshMoney's `{currency, amount}` tuple form below).
  defp cell(%Money{amount: amount, currency: currency}) do
    "#{currency} #{Decimal.to_string(amount, :normal)}"
  end

  # ADR-036 D5/H7 (Percent/Score rows): the canonical CSV cell for either bounded
  # decimal scalar is the plain decimal string ("42.5" / "87") — no thousands
  # grouping, so `decode_cell/1` → the governed action's `cast_input` parses it
  # losslessly. Without this clause a bare %Decimal{} would fall through to the
  # generic map/JSON branch below (it is a struct) and mis-serialize as a JSON
  # object of its internal coef/exp/sign fields.
  defp cell(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp cell(value) when is_binary(value), do: value
  defp cell(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp cell(value) when is_map(value) or is_list(value), do: value |> compact() |> Jason.encode!()
  defp cell(value), do: to_string(value)

  # ADR-036 D5/H7 (Duration row): the canonical CSV cell is ISO-8601 (`"PT5400S"`).
  # `Samen.Type.Duration`'s Ash VALUE is a bare non-negative integer (seconds) — no
  # wrapper struct the way Money/Percent/Score have — so `cell/1` alone cannot tell
  # "this integer is a Duration" from any other plain integer column by shape. This
  # thin wrapper checks the COLUMN'S declared Ash type before falling to the
  # value-shape dispatch every other cell already uses; every non-Duration column
  # (including every other integer-valued attribute) is byte-identical to `cell/1`.
  # `decode_cell/1` needs NO matching change: `Samen.Type.Duration.cast_input/2`
  # already accepts an ISO-8601 string directly (and bare seconds too, for the
  # pre-T15 fixtures/imports that still write one).
  defp cell_for_column(seconds, resource, col) when is_integer(seconds) do
    case attr_type(resource, col) do
      Samen.Type.Duration -> duration_iso8601(seconds)
      _ -> cell(seconds)
    end
  end

  defp cell_for_column(value, _resource, _col), do: cell(value)

  defp attr_type(resource, col) do
    case Ash.Resource.Info.attribute(resource, col) do
      %{type: type} -> type
      _ -> nil
    end
  end

  defp duration_iso8601(seconds) when is_integer(seconds) and seconds >= 0 do
    [second: seconds] |> Duration.new!() |> Duration.to_iso8601()
  end

  # D7 / ADR-046 §4.6 — a %Masked{} nested INSIDE a container cell (a `:map`/list
  # column value) must serialize as its MASKED representation (`••••` via its own
  # Jason.Encoder), NEVER unwrapped to its `vt_*` token. Without this clause the
  # generic struct clause below would `Map.from_struct/1` it into
  # `{"token":"vt_…","label":…}`, defeating the module's "NEVER a vt_* token"
  # guarantee for any nested occurrence. Kept BEFORE the generic struct clause so
  # the masked wrapper is preserved (Jason then renders it `••••`). The top-level
  # `cell(%Samen.Masked{})` clause already covers the direct (non-nested) case.
  defp compact(%Samen.Masked{} = masked), do: masked

  defp compact(%_{} = struct), do: struct |> Map.from_struct() |> compact()

  defp compact(%{} = map),
    do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {k, compact(v)} end)

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(other), do: other

  defp validate_columns(resource, nil), do: {:ok, columns(resource)}

  defp validate_columns(resource, requested) do
    allowed = columns(resource)

    case Enum.reject(requested, &(&1 in allowed)) do
      [] -> {:ok, requested}
      unknown -> {:error, {:unknown_columns, unknown}}
    end
  end

  # -- import internals --------------------------------------------------------

  # Fail-closed header validation (AC-G15-5): every header name must be an
  # importable public attribute; `id`/`org_id`/timestamps/unknown/private names
  # reject the whole file. String.to_existing_atom never mints atoms.
  defp validate_mapping(resource, header) do
    allowed = columns(resource)

    mapped =
      Enum.map(header, fn name ->
        try do
          atom = String.to_existing_atom(name)
          if atom in allowed, do: {:ok, atom}, else: {:bad, name}
        rescue
          ArgumentError -> {:bad, name}
        end
      end)

    case for {:bad, name} <- mapped, do: name do
      [] -> {:ok, for({:ok, atom} <- mapped, do: atom)}
      bad -> {:error, {:bad_mapping, bad}}
    end
  end

  defp import_row(resource, action, scope, cols, row, n, %Report{} = report) do
    # org_id comes from the ACTING scope, never from the CSV (the mapping already
    # rejected an org_id column) — a row can only ever land in the caller's org.
    attrs =
      cols
      |> Enum.zip(row)
      |> Enum.reject(fn {_col, value} -> value == "" end)
      |> Map.new(fn {col, value} -> {col, decode_cell(value)} end)
      |> Map.put(:org_id, scope_org_id(scope))

    # The scope goes into for_create/4 so the governed changes (WriteGuard,
    # Vault.Change) see the acting actor at BUILD time — the same call shape the
    # UI forms and Samen.Factory use.
    resource
    |> Ash.Changeset.for_create(action, attrs, scope: scope)
    |> Ash.create()
    |> case do
      {:ok, _record} ->
        %Report{report | created: report.created + 1}

      {:error, error} ->
        %Report{report | errors: [%{row: n, error: error_message(error)} | report.errors]}
    end
  rescue
    # A cast/validation raise is that ROW's failure, not the import's.
    e -> %Report{report | errors: [%{row: n, error: Exception.message(e)} | report.errors]}
  end

  # A cell that parses as a JSON object/array is a composite value (the export
  # form of FullName/Emails/Phones/custom maps); anything else stays a string for
  # the governed action's own cast.
  defp decode_cell(<<c, _::binary>> = value) when c in [?{, ?[] do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_cell(value), do: value

  defp error_message(%{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, "; ", &error_message/1)
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  # -- RFC 4180 (ship note: hand-rolled, no dependency) ------------------------

  @doc false
  # Serialize ONE already-plane-resolved value exactly as an export row cell does —
  # the same private `cell/1` path `export_rows/8` uses. Exposed (doc-false) so the
  # D7 container-nested-masking proof can exercise the real serialization boundary a
  # nested `%Masked{}` flows through (a nested masked must render `••••`, never its
  # `vt_*` token). Not part of the public CSV API.
  def render_cell(value), do: cell(value)

  @doc "Serialize rows (list of list-of-strings) as RFC-4180 CSV (CRLF, quoted as needed)."
  def serialize(rows) do
    Enum.map_join(rows, "", fn row -> Enum.map_join(row, ",", &escape/1) <> "\r\n" end)
  end

  defp escape(value) do
    # Formula-neutralize BEFORE RFC-4180 quoting, so every export cell is safe by
    # construction: a live-formula lead is defanged to literal text at the one
    # serialization chokepoint, then quoted as RFC-4180 requires.
    value = value |> to_string() |> neutralize_formula()

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  # A cell whose first character can be evaluated by a spreadsheet is prefixed with a
  # single quote so the app renders it as literal TEXT, not a formula. A cell that is a
  # plain number (e.g. a legitimate negative amount `-5`) is EXEMPT so numeric columns
  # stay numeric — `-2+3+cmd|'/C calc'!A1` is not a number, so it is still neutralized.
  defp neutralize_formula(<<lead, _::binary>> = value) when lead in @formula_leads do
    if numeric?(value), do: value, else: "'" <> value
  end

  defp neutralize_formula(value), do: value

  defp numeric?(value), do: match?({_parsed, ""}, Float.parse(value))

  @doc """
  Parse an RFC-4180 CSV binary into a list of rows (each a list of string cells).
  Handles quoted cells, escaped quotes (`\"\"`), embedded commas/newlines, and
  CRLF/LF row endings. A trailing newline yields no empty row.
  """
  def parse(binary) when is_binary(binary) do
    parse_rows(binary, "", [], [])
  end

  defp parse_with_header(csv) do
    case parse(csv) do
      [] -> {:error, :empty}
      [_header_only] -> {:error, :empty}
      [header | rows] -> {:ok, header, rows}
    end
  end

  # cell = the cell being accumulated; row = cells so far; rows = finished rows.
  defp parse_rows(<<"\"", rest::binary>>, "", row, rows), do: parse_quoted(rest, "", row, rows)

  defp parse_rows(<<",", rest::binary>>, cell, row, rows),
    do: parse_rows(rest, "", [cell | row], rows)

  defp parse_rows(<<"\r\n", rest::binary>>, cell, row, rows),
    do: parse_rows(rest, "", [], [finish_row(cell, row) | rows])

  defp parse_rows(<<"\n", rest::binary>>, cell, row, rows),
    do: parse_rows(rest, "", [], [finish_row(cell, row) | rows])

  defp parse_rows(<<c::utf8, rest::binary>>, cell, row, rows),
    do: parse_rows(rest, cell <> <<c::utf8>>, row, rows)

  defp parse_rows(<<>>, "", [], rows), do: Enum.reverse(rows)
  defp parse_rows(<<>>, cell, row, rows), do: Enum.reverse([finish_row(cell, row) | rows])

  # Inside a quoted cell: "" is an escaped quote; a lone " closes the cell.
  defp parse_quoted(<<"\"\"", rest::binary>>, cell, row, rows),
    do: parse_quoted(rest, cell <> "\"", row, rows)

  defp parse_quoted(<<"\"", rest::binary>>, cell, row, rows),
    do: parse_rows(rest, cell, row, rows)

  defp parse_quoted(<<c::utf8, rest::binary>>, cell, row, rows),
    do: parse_quoted(rest, cell <> <<c::utf8>>, row, rows)

  # Unterminated quote: treat the remainder as the cell (fail-soft parse; the
  # governed action still validates every value).
  defp parse_quoted(<<>>, cell, row, rows), do: parse_rows(<<>>, cell, row, rows)

  defp finish_row(cell, row), do: Enum.reverse([cell | row])
end
