defmodule DemoWeb.Api.PageLimitClamp do
  @moduledoc """
  Local mirror of `Samen.Web.Api.PageLimitClamp` (the canonical framework plug —
  see its moduledoc for the upstream Ash `to_page` raw-limit-split bug this works
  around). Demo deliberately depends ONLY on samen_core (it is the kernel's
  standalone reference app), so it cannot use the samen_web module; keep this
  mirror byte-for-byte in sync with the canonical clamp semantics.
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

          _ ->
            conn
        end

      _ ->
        conn
    end
  end
end
