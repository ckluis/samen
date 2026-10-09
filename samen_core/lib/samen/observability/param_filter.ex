defmodule Samen.Observability.ParamFilter do
  @moduledoc """
  The framework keep-list, made safe against NESTED values (ADR-052 §2.1.2 item 2).

  Phoenix's `{:keep, keys}` filter (`Phoenix.Logger.filter_values/2`) keeps the WHOLE value under
  a kept key: `id[x]=alice@example.com` arrives as `%{"id" => %{"x" => "alice@example.com"}}` and
  is logged in the clear, and so is every field of a form posted under a kept root (`org[...]`).
  Phoenix offers no hook into that function, so this module sits in front of it:

    * `filter_values/2` — Phoenix's keep semantics with one change: a kept key keeps its value
      only when that value is a SCALAR (string, number, boolean, atom, nil). A map or list under
      a kept key is filtered like any other subtree (each nested key kept only if it is itself
      kept and scalar), and a struct is `[FILTERED]` whole. A deny-list filter is passed through
      untouched (the `:logger` tier already fails a host that configures one).
    * `install/0` — re-attaches every `:telemetry` handler owned by `Phoenix.Logger` and
      `Phoenix.LiveView.Logger` (the two modules that print params) under its SAME id, wrapped:
      the wrapper replaces `metadata.params` / `metadata.conn.params` (and the LiveView mount's
      `metadata.session`, which LiveView prints unfiltered) with `filter_values/1`'s output, then
      calls Phoenix's own handler. Phoenix's keep filter then runs over values that
      are already scalar-or-`[FILTERED]`, so the composition is exactly this module's filter.

  Wired by `Samen.Observability.child_specs/2`, ON by default (`param_filter: false` opts out).
  Idempotent: a handler already wrapped is left alone. If the sanitizer itself fails, the params
  are replaced by `"[FILTERED]"` whole — never passed through raw.
  """

  @filtered "[FILTERED]"
  @owners [Phoenix.Logger, Phoenix.LiveView.Logger]

  @doc "The modules whose telemetry handlers print request / event params."
  @spec owners() :: [module()]
  def owners, do: @owners

  @doc """
  Filter `params` like Phoenix's keep-list, keeping a kept key's value only when it is a scalar.
  `filter` defaults to the running `config :phoenix, :filter_parameters`.
  """
  @spec filter_values(term(), term()) :: term()
  def filter_values(params, filter \\ Application.get_env(:phoenix, :filter_parameters, []))

  # `Plug.Conn.Unfetched` carries no values; Phoenix prints it as "[UNFETCHED]".
  def filter_values(%{__struct__: Plug.Conn.Unfetched} = unfetched, _filter), do: unfetched
  def filter_values(params, {:keep, keys}) when is_list(keys), do: keep(params, keys)
  def filter_values(params, _deny_list_or_other), do: params

  defp keep(%{__struct__: _}, _keys), do: @filtered

  defp keep(%{} = map, keys) do
    Map.new(map, fn {k, v} ->
      if is_binary(k) and k in keys and scalar?(v), do: {k, v}, else: {k, keep(v, keys)}
    end)
  end

  defp keep([_ | _] = list, keys), do: Enum.map(list, &keep(&1, keys))
  defp keep(_other, _keys), do: @filtered

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_atom(v)

  # ---------------------------------------------------------------------------
  # Wrapping Phoenix's own handlers

  @doc """
  Wrap every attached `Phoenix.Logger` / `Phoenix.LiveView.Logger` handler (same id, same
  events) so the params it prints pass through `filter_values/1` first. Returns the number of
  handlers wrapped by this call (already-wrapped ones are skipped).
  """
  @spec install() :: non_neg_integer()
  def install do
    for %{id: id, event_name: event, function: fun, config: config} <- phoenix_handlers(),
        owner(fun) in @owners,
        reduce: 0 do
      n ->
        :ok = :telemetry.detach(id)
        :ok = :telemetry.attach(id, event, &__MODULE__.handle_event/4, {fun, config})
        n + 1
    end
  end

  @doc "Restore Phoenix's own handlers (tests). Returns the number restored."
  @spec uninstall() :: non_neg_integer()
  def uninstall do
    for %{id: id, event_name: event, function: fun, config: {orig, orig_config}} <-
          phoenix_handlers(),
        owner(fun) == __MODULE__,
        reduce: 0 do
      n ->
        :ok = :telemetry.detach(id)
        :ok = :telemetry.attach(id, event, orig, orig_config)
        n + 1
    end
  end

  @doc "Is every Phoenix param-logging handler currently wrapped?"
  @spec installed?() :: boolean()
  def installed? do
    not Enum.any?(phoenix_handlers(), &(owner(&1.function) in @owners))
  end

  @doc false
  # The wrapper: sanitize, then hand over to Phoenix's own handler.
  def handle_event(event, measurements, metadata, {fun, config}) do
    fun.(event, measurements, sanitize(metadata), config)
  end

  defp sanitize(%{} = metadata) do
    # LiveView's mount line also prints the session verbatim; it gets the same keep-list.
    metadata
    |> sanitize_key(:params)
    |> sanitize_key(:session)
    |> sanitize_conn()
  end

  defp sanitize(metadata), do: metadata

  defp sanitize_key(metadata, key) do
    case metadata do
      %{^key => params} -> Map.put(metadata, key, safe_filter(params))
      _ -> metadata
    end
  end

  defp sanitize_conn(%{conn: %{params: params} = conn} = metadata),
    do: Map.put(metadata, :conn, Map.put(conn, :params, safe_filter(params)))

  defp sanitize_conn(metadata), do: metadata

  # Never raise (a raising handler is detached, and its crash report would print the params),
  # never pass raw params on: on any failure the whole value is filtered.
  defp safe_filter(params) do
    filter_values(params)
  rescue
    _ -> @filtered
  catch
    _, _ -> @filtered
  end

  defp phoenix_handlers, do: :telemetry.list_handlers([:phoenix])

  defp owner(fun) when is_function(fun) do
    case Function.info(fun, :module) do
      {:module, module} -> module
      _ -> nil
    end
  end

  defp owner(_), do: nil
end
