defmodule Samen.Web.Api.PageLimitClamp do
  @moduledoc """
  Boundary clamp for JSON:API `page[limit]` (WS-A AC-G1-6 / RP-G1-6).

  Ash's action-level `max_page_size` clamps the QUERY limit, but upstream Ash
  (3.x, `Ash.Actions.Read.to_page/7`) splits the fetched rows at the RAW
  REQUESTED limit (`Enum.split(data, page_opts[:limit])`) rather than the
  clamped effective limit. A keyset read fetches `effective_limit + 1` rows for
  the `more?` look-ahead, so a request with `page[limit]` ABOVE `max_page_size`
  leaks the look-ahead row into the response (cap + 1 rows) and mis-reports
  `more?`. Requests at or below the cap are unaffected.

  This plug restores the declared guarantee structurally: it clamps
  `page[limit]` to `:max` (default 200 — the convention every `:api_read`
  action in a Samen blueprint declares) BEFORE the AshJsonApi router runs, so
  Ash never sees an over-max limit and the exact-cap semantics hold.

  Mount it in the host's API endpoint ahead of the AshJsonApi router:

      plug(Samen.Web.Api.PageLimitClamp)
      plug(HostWeb.Api.Router)

  Remove once the upstream split is fixed to use the effective limit.
  """

  @behaviour Plug

  @default_max 200

  @impl true
  def init(opts), do: Keyword.get(opts, :max, @default_max)

  @impl true
  def call(conn, max) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params do
      %{"page" => %{"limit" => limit} = page} when is_binary(limit) ->
        case Integer.parse(limit) do
          {n, ""} when n > max ->
            clamped = Map.put(page, "limit", Integer.to_string(max))

            conn
            |> Map.update!(:query_params, &Map.put(&1, "page", clamped))
            |> Map.update!(:params, &Map.put(&1, "page", clamped))

          # Non-integer / in-bounds limits pass through untouched — Ash's own
          # validation owns rejecting malformed page params.
          _ ->
            conn
        end

      _ ->
        conn
    end
  end
end
