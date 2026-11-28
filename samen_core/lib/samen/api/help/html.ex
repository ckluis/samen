defmodule Samen.Api.Help.Html do
  @moduledoc """
  The HTML form of a `Samen.Api.Help` map (the same map the JSON answer carries, nothing added). Every value is
  escaped with `Phoenix.HTML`. A field the API omits without a reveal grant shows `••••` where a value would be: the
  page says the field exists and that its value is withheld, never what the value is.
  """

  @mask "••••"

  @doc "The page for an index (`:index`) or one resource (`:detail`) map."
  @spec render(map(), :index | :detail) :: String.t()
  def render(map, :index), do: page("API help", index(map))
  def render(map, :detail), do: page(map["label"] || map["type"], detail(map))

  defp index(map) do
    rows =
      for r <- map["resources"] do
        "<tr><td><a href=\"#{attr(r["links"]["help"])}\">#{e(r["label"])}</a></td><td><code>#{e(r["type"])}</code></td>" <>
          "<td>#{e(r["description"])}</td><td>#{e(Enum.join(r["actions"], ", "))}</td></tr>"
      end

    "<h1>API help</h1>" <>
      "<p>Signed in as <code>#{e(map["caller"]["plane"])}</code> / <code>#{e(map["caller"]["role"])}</code>.</p>" <>
      scopes(map["caller"]["scopes"]) <>
      "<p>Base <code>#{e(map["api"]["base"])}</code>, media type <code>#{e(map["api"]["media_type"])}</code>.</p>" <>
      table(["Resource", "Type", "Description", "Actions"], rows)
  end

  defp scopes(nil), do: ""

  defp scopes(scopes) do
    items = for {k, v} <- Enum.sort(scopes), do: "<code>#{e(k)}</code>: #{e(Enum.join(v, ", "))}"
    "<p>Key scopes: " <> if(items == [], do: "none", else: Enum.join(items, "; ")) <> "</p>"
  end

  defp detail(map) do
    fields =
      for f <- map["fields"] do
        "<tr><td><code>#{e(f["name"])}</code></td><td>#{e(f["label"])}</td><td>#{e(f["type"])}</td>" <>
          "<td>#{yes(f["required"])}</td><td>#{yes(f["read_only"])}</td><td>#{yes(f["pii"])}</td><td>#{delivery(f["delivery"])}</td></tr>"
      end

    actions =
      for a <- map["actions"] do
        "<tr><td><code>#{e(a["name"])}</code></td><td>#{e(a["class"])}</td><td>#{e(a["method"])}</td>" <>
          "<td><code>#{e(a["path"])}</code></td><td><code>#{e(a["scope"])}</code></td><td>#{e(Enum.join(a["required_args"], ", "))}</td></tr>"
      end

    relations =
      for r <- map["relations"] do
        "<tr><td><code>#{e(r["name"])}</code></td><td>#{e(r["kind"])}</td><td><code>#{e(r["field"])}</code></td>" <>
          "<td><a href=\"#{attr(map["links"]["index"])}/#{attr(r["target"])}\">#{e(r["target"])}</a></td></tr>"
      end

    "<p><a href=\"#{attr(map["links"]["index"])}\">All resources</a></p><h1>#{e(map["label"])}</h1>" <>
      "<p>#{e(map["description"])}</p><p>Type <code>#{e(map["type"])}</code>, scope family <code>#{e(map["family"])}</code>.</p>" <>
      "<h2>Actions</h2>" <>
      table(["Name", "Class", "Method", "Path", "Scope", "Required arguments"], actions) <>
      "<h2>Fields</h2>" <>
      table(["Name", "Label", "Type", "Required", "Read only", "PII", "Delivery"], fields) <>
      "<h2>Relations</h2>" <> table(["Name", "Kind", "Field", "Target"], relations)
  end

  defp delivery("clear"), do: "clear"
  defp delivery("omitted_without_grant"), do: "#{@mask} omitted without a reveal grant"
  defp delivery(other), do: e(other)

  defp yes(true), do: "yes"
  defp yes(_), do: "no"

  defp table(head, rows) do
    "<table><thead><tr>" <>
      Enum.map_join(head, &"<th>#{&1}</th>") <> "</tr></thead><tbody>" <> Enum.join(rows) <> "</tbody></table>"
  end

  defp page(title, body) do
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" <>
      "<title>#{e(title)}</title><style>body{font:15px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:64rem;padding:0 1rem}" <>
      "table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border-bottom:1px solid #8884;padding:.35rem .5rem;text-align:left;vertical-align:top}" <>
      "code{font-family:ui-monospace,monospace}</style></head><body>" <> body <> "</body></html>"
  end

  defp e(nil), do: ""
  defp e(value), do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp attr(value), do: e(value)
end
