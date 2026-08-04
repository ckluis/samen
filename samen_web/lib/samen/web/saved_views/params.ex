defmodule Samen.Web.SavedViews.Params do
  @moduledoc """
  Serialization + UNTRUSTED restore of a saved view's params blob (G10, T58).

  A saved view stores QUERY STATE — the chosen view TYPE plus sort / filter / group / column
  / date-field / window / caps — as a JSON-safe `:map`. This module owns the two directions,
  and the security posture is DIFFERENT on each:

    * `serialize/4` (SAVE — STRICT): every field reference is validated against the surface
      `Whitelist` and the stored-filter PII gate. A reference to a NON-whitelisted field is
      REFUSED (`{:error, {:field_not_whitelisted, …}}`); a FILTER/SORT/GROUP/DATE reference
      to a VAULT-ROUTED (🔒) field is REFUSED (`{:error, {:vaulted_field, field}}`) so
      plaintext PII can never be persisted outside the vault (INV-1). Output is a JSON-safe,
      string-keyed map.

    * `restore/2` (RESTORE — UNTRUSTED, LENIENT): the stored blob is treated as HOSTILE. Every
      field reference is re-validated against the whitelist and re-checked for vault-routing;
      anything not whitelisted, vaulted (for filter/sort/group/date), or malformed is DROPPED
      (never crashes the restore). UNKNOWN keys (`"org_id"`, `"authorize?"`, an injected raw
      query string) are simply not read → ignored. Field references are matched against the
      BOUNDED compile-time atom lists (never `String.to_atom/1` on the blob), and values are
      only ever a parameterized freeform filter string or clamped integers/dates — there is
      no path from the blob to a raw Ash expression, an atom-exhaustion, or an org_id override.
      Org/user scope is re-applied by the CALLER's read (from the actor), NEVER from the blob.

  The restored `%Samen.Web.ListState{}` carries `sort`/`filter`/`page_size`/`show_archived`;
  the accompanying `view_params` map carries the view-type extras (`group_by`, `columns`,
  `date_field`, `filters`, `window`, `caps`) for the WS-G view component.
  """

  alias Samen.Web.ListState
  alias Samen.Web.Reads
  alias Samen.Web.SavedViews.Whitelist

  @view_types [
    :table,
    :board,
    :kanban,
    :calendar,
    :timeline,
    :gantt,
    :gallery,
    :tree,
    :chart,
    :dashboard
  ]

  # Bounded integer caps a stored blob may carry — each clamped on restore (a hostile blob
  # cannot request an unbounded page/group/marker set).
  @cap_clampers %{
    "page_size" => &Reads.bounded_page_size/1,
    "per_group" => &Reads.bounded_group_cap/1,
    "max_groups" => &__MODULE__.clamp_max_groups/1,
    "max_points" => &Reads.bounded_agg_points/1,
    "sibling_limit" => &Reads.bounded_tree_sibling_limit/1,
    "max_depth" => &Reads.bounded_tree_max_depth/1,
    "max_nodes" => &Reads.bounded_tree_max_nodes/1,
    "markers" => &Reads.bounded_markers/1
  }

  @doc "The bounded set of view-type atoms a saved view may carry."
  @spec view_types() :: [atom()]
  def view_types, do: @view_types

  @doc false
  def clamp_max_groups(n) when is_integer(n) and n >= 1, do: min(n, Reads.default_max_groups())
  def clamp_max_groups(_), do: Reads.default_max_groups()

  # ---------------------------------------------------------------------------
  # SAVE — strict
  # ---------------------------------------------------------------------------

  @doc """
  Serialize `view_type` + a `%ListState{}` + a `view_params` map into a JSON-safe, string-keyed
  params map, validating STRICTLY against `whitelist`. Returns `{:ok, map}` or `{:error, reason}`.

  `view_params` (all optional): `:group_by`, `:columns`, `:date_field`, `:filters`
  (`%{field => value}` structured predicates), `:window` (`%{start:, end:}`), `:caps`
  (`%{page_size:, per_group:, …}`).
  """
  @spec serialize(atom(), ListState.t(), map(), Whitelist.t()) ::
          {:ok, map()} | {:error, term()}
  def serialize(view_type, %ListState{} = state, view_params, %Whitelist{} = wl)
      when is_map(view_params) do
    with :ok <- validate_view_type(view_type),
         {:ok, sort} <- ser_sort(state.sort, wl),
         {:ok, group_by} <- ser_field(Map.get(view_params, :group_by), :group, wl, vault_refuse: true),
         {:ok, date_field} <- ser_field(Map.get(view_params, :date_field), :date, wl, vault_refuse: true),
         {:ok, columns} <- ser_columns(Map.get(view_params, :columns, []), wl),
         {:ok, filters} <- ser_filters(Map.get(view_params, :filters, %{}), wl) do
      base =
        %{
          "view_type" => Atom.to_string(view_type),
          "filter" => filter_string(state.filter),
          "page_size" => Reads.bounded_page_size(state.page_size),
          "show_archived" => state.show_archived == true,
          "columns" => columns,
          "filters" => filters,
          "caps" => ser_caps(Map.get(view_params, :caps, %{})),
          "window" => ser_window(Map.get(view_params, :window))
        }
        |> put_opt("sort", sort)
        |> put_opt("group_by", group_by)
        |> put_opt("date_field", date_field)

      {:ok, base}
    end
  end

  # ---------------------------------------------------------------------------
  # RESTORE — untrusted, lenient
  # ---------------------------------------------------------------------------

  @doc """
  Restore an UNTRUSTED stored `params` map (string-keyed jsonb from the SavedView row) into a
  sanitized `{view_type, %ListState{}, view_params}` triple, validated against `whitelist`.
  Never raises: every unsafe/unknown element is dropped. See moduledoc for the threat posture.
  """
  @spec restore(map(), Whitelist.t()) :: {atom(), ListState.t(), map()}
  def restore(params, %Whitelist{} = wl) when is_map(params) do
    view_type = restore_view_type(Map.get(params, "view_type"))

    state = %ListState{
      sort: restore_sort(Map.get(params, "sort"), wl),
      filter: filter_string(Map.get(params, "filter")),
      page_size: restore_page_size(params, wl),
      show_archived: Map.get(params, "show_archived") == true
    }

    view_params = %{
      group_by: restore_field(Map.get(params, "group_by"), :group, wl, vault_refuse: true),
      date_field: restore_field(Map.get(params, "date_field"), :date, wl, vault_refuse: true),
      columns: restore_columns(Map.get(params, "columns"), wl),
      filters: restore_filters(Map.get(params, "filters"), wl),
      caps: restore_caps(Map.get(params, "caps")),
      window: restore_window(Map.get(params, "window"))
    }

    {view_type, state, view_params}
  end

  def restore(_params, %Whitelist{} = wl), do: restore(%{}, wl)

  # -- serialize helpers (strict) ----------------------------------------------

  defp validate_view_type(vt) when vt in @view_types, do: :ok
  defp validate_view_type(vt), do: {:error, {:bad_view_type, vt}}

  defp ser_sort(nil, _wl), do: {:ok, nil}

  defp ser_sort({field, dir}, wl) when is_atom(field) and dir in [:asc, :desc] do
    with {:ok, resolved} <- ser_field(field, :sort, wl, vault_refuse: true) do
      {:ok, [Atom.to_string(resolved), Atom.to_string(dir)]}
    end
  end

  defp ser_sort(other, _wl), do: {:error, {:bad_sort, other}}

  # Resolve one field reference for `role`. `vault_refuse: true` fails on a vaulted field
  # (the stored-filter PII gate). `nil` input passes through as `{:ok, nil}` (optional field).
  defp ser_field(nil, _role, _wl, _opts), do: {:ok, nil}

  defp ser_field(value, role, wl, opts) do
    case Whitelist.resolve(wl, role, value) do
      nil ->
        {:error, {:field_not_whitelisted, {role, value}}}

      field ->
        if Keyword.get(opts, :vault_refuse, false) and not Whitelist.non_vaulted?(wl, field) do
          {:error, {:vaulted_field, field}}
        else
          {:ok, field}
        end
    end
  end

  defp ser_columns(cols, wl) when is_list(cols) do
    # Columns are display-only (masked on render) — whitelisted but NOT vault-refused.
    Enum.reduce_while(cols, {:ok, []}, fn c, {:ok, acc} ->
      case Whitelist.resolve(wl, :column, c) do
        nil -> {:halt, {:error, {:field_not_whitelisted, {:column, c}}}}
        field -> {:cont, {:ok, [Atom.to_string(field) | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp ser_columns(_cols, _wl), do: {:ok, []}

  # Structured field predicates — THE stored-filter PII gate. A predicate on a vaulted
  # field is REFUSED (its value would be plaintext PII outside the vault).
  defp ser_filters(filters, wl) when is_map(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case Whitelist.resolve(wl, :filter, k) do
        nil ->
          {:halt, {:error, {:field_not_whitelisted, {:filter, k}}}}

        field ->
          if Whitelist.non_vaulted?(wl, field) do
            {:cont, {:ok, Map.put(acc, Atom.to_string(field), scalar(v))}}
          else
            {:halt, {:error, {:vaulted_field, field}}}
          end
      end
    end)
  end

  defp ser_filters(_filters, _wl), do: {:ok, %{}}

  defp ser_caps(caps) when is_map(caps) do
    for {k, v} <- caps, key = to_string(k), Map.has_key?(@cap_clampers, key), into: %{} do
      {key, Map.fetch!(@cap_clampers, key).(v)}
    end
  end

  defp ser_caps(_), do: %{}

  defp ser_window(%{} = w) do
    %{}
    |> put_opt("start", iso(Map.get(w, :start) || Map.get(w, "start")))
    |> put_opt("end", iso(Map.get(w, :end) || Map.get(w, "end")))
  end

  defp ser_window(_), do: %{}

  # -- restore helpers (untrusted) ---------------------------------------------

  defp restore_view_type(v) when is_binary(v) do
    Enum.find(@view_types, :table, fn vt -> Atom.to_string(vt) == v end)
  end

  defp restore_view_type(_), do: :table

  defp restore_sort([field, dir], wl) when is_binary(field) and is_binary(dir) do
    with f when not is_nil(f) <- Whitelist.resolve(wl, :sort, field),
         true <- Whitelist.non_vaulted?(wl, f),
         d when d in [:asc, :desc] <- restore_dir(dir) do
      {f, d}
    else
      _ -> nil
    end
  end

  defp restore_sort(_other, _wl), do: nil

  defp restore_dir("asc"), do: :asc
  defp restore_dir("desc"), do: :desc
  defp restore_dir(_), do: nil

  defp restore_field(value, role, wl, opts) do
    case Whitelist.resolve(wl, role, value) do
      nil ->
        nil

      field ->
        if Keyword.get(opts, :vault_refuse, false) and not Whitelist.non_vaulted?(wl, field),
          do: nil,
          else: field
    end
  end

  defp restore_columns(cols, wl) when is_list(cols) do
    cols
    |> Enum.map(&Whitelist.resolve(wl, :column, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp restore_columns(_cols, _wl), do: []

  defp restore_filters(filters, wl) when is_map(filters) do
    for {k, v} <- filters,
        field = Whitelist.resolve(wl, :filter, k),
        not is_nil(field),
        Whitelist.non_vaulted?(wl, field),
        into: %{} do
      {field, scalar(v)}
    end
  end

  defp restore_filters(_filters, _wl), do: %{}

  defp restore_page_size(params, wl) do
    case Map.get(params, "page_size") do
      n when is_integer(n) -> Reads.bounded_page_size(n)
      _ -> Whitelist.default_page_size(wl)
    end
  end

  defp restore_caps(caps) when is_map(caps) do
    for {k, v} <- caps, Map.has_key?(@cap_clampers, to_string(k)), into: %{} do
      {to_string(k), Map.fetch!(@cap_clampers, to_string(k)).(v)}
    end
  end

  defp restore_caps(_), do: %{}

  defp restore_window(%{} = w) do
    %{}
    |> put_opt(:start, date(Map.get(w, "start")))
    |> put_opt(:end, date(Map.get(w, "end")))
  end

  defp restore_window(_), do: %{}

  # -- shared ------------------------------------------------------------------

  defp filter_string(s) when is_binary(s), do: s
  defp filter_string(_), do: ""

  # Only JSON-safe scalars survive as filter values (a nested map/list predicate value is
  # not a supported predicate — coerced to string, never executed as a structure).
  defp scalar(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp scalar(nil), do: nil
  defp scalar(v), do: to_string(v)

  defp iso(%Date{} = d), do: Date.to_iso8601(d)
  defp iso(s) when is_binary(s), do: if(match?({:ok, _}, Date.from_iso8601(s)), do: s, else: nil)
  defp iso(_), do: nil

  defp date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, _key, %{} = empty) when map_size(empty) == 0, do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)
end
