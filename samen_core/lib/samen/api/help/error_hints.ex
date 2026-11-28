defmodule Samen.Api.Help.ErrorHints do
  @moduledoc """
  Points an API error at `/help`. A host mounts it FIRST in its API endpoint:

      plug(Samen.Api.Help.ErrorHints, router: MyWeb.Api.Router)

  Before the response is sent, every error of a `status >= 400` JSON:API body gets `meta._hint` (a sentence from a
  fixed table keyed by the error's `code`, never built from its `detail`, which can carry a value), `meta.help` and
  `links.about`, each only when the error does not already carry one. A success body (and any body that is not
  `application/vnd.api+json`) is untouched, byte for byte. The hint is in `meta` because JSON:API 1.1 forbids extra
  members in an error object.

  The link names a type only when the caller may use it (`Samen.Api.Help.visible_types/2`); otherwise, for an unknown
  caller or a hidden type, it is the index, so an error never says a hidden type exists. A key that holds no scope at
  all is told so (`key_has_no_scopes`); that refusal is counted (telemetry `[:samen, :api, :help, :key_has_no_scopes]`),
  not logged, because a key without scopes meets it on every request. Only the resource the request addressed is asked
  about; no other type is evaluated. An error whose `meta` or `links` is not a map keeps it as it is.

  (AshJsonApi's per-domain `error_handler` is not used: it sees neither the conn nor the actor, so it cannot tell a
  hidden type from a visible one.)
  """
  @behaviour Plug

  import Plug.Conn

  alias Samen.Api.Help

  @hints %{
    "forbidden" => "Not permitted for this key. GET %{help} lists the actions it may run.",
    "not_found" => "Nothing was found at that address. GET %{help} lists the resources this key may read.",
    "no_route_found" => "No such route. GET %{help} lists the routes this key may use.",
    "required" => "A required value is missing. GET %{help} lists the fields and arguments.",
    "service_unavailable" => "The credential could not be checked right now. Retry shortly; GET %{help} describes this key once it can be checked.",
    "key_has_no_scopes" => "This key has no scopes, so it authorizes nothing. Mint a key with at least one scope."
  }
  @invalid_hint "The request was not valid. GET %{help} describes the fields and actions this key may use."
  @generic_hint "The request failed. GET %{help} describes what this key may do."

  @impl true
  def init(opts), do: %{router: Keyword.fetch!(opts, :router), help: Keyword.get(opts, :help, "/api/help")}

  @impl true
  def call(conn, opts), do: register_before_send(conn, &hint(&1, opts))

  defp hint(%{status: status} = conn, opts) when is_integer(status) and status >= 400 do
    with true <- vnd_api?(conn),
         {:ok, %{"errors" => [_ | _] = errors} = body} when is_map(body) <- decode(conn.resp_body) do
      actor = Ash.PlugHelpers.get_actor(conn)
      link = link(conn, actor, opts)
      no_scopes? = no_scopes?(actor)
      if no_scopes? and Enum.any?(errors, &(is_map(&1) and &1["code"] == "forbidden")),
        do: :telemetry.execute([:samen, :api, :help, :key_has_no_scopes], %{count: 1}, %{})

      errors = Enum.map(errors, &annotate(&1, link, opts.help, no_scopes?))
      %{conn | resp_body: Jason.encode!(Map.put(body, "errors", errors))}
    else
      _ -> conn
    end
  end

  defp hint(conn, _opts), do: conn

  defp annotate(%{} = error, link, index, no_scopes?) do
    code = error["code"]
    key = if no_scopes? and code == "forbidden", do: "key_has_no_scopes", else: code
    defaults = %{"_hint" => text(key, index), "help" => link}

    error
    |> put_map("meta", fn meta -> Map.merge(defaults, meta) end, defaults)
    |> put_map("links", &Map.put_new(&1, "about", link), %{"about" => link})
  end

  defp annotate(other, _link, _index, _no_scopes?), do: other

  defp text(key, index) do
    template =
      cond do
        is_map_key(@hints, key) -> Map.fetch!(@hints, key)
        is_binary(key) and String.starts_with?(key, "invalid_") -> @invalid_hint
        true -> @generic_hint
      end

    String.replace(template, "%{help}", index)
  end

  # Absent: the new map. A map: merged (what the error already carries wins). Anything else: left as it is.
  defp put_map(error, field, merge, fresh) do
    case Map.fetch(error, field) do
      :error -> Map.put(error, field, fresh)
      {:ok, nil} -> Map.put(error, field, fresh)
      {:ok, %{} = existing} -> Map.put(error, field, merge.(existing))
      {:ok, _other} -> error
    end
  end

  # The first path segment names a type only if the router serves it AND the caller may use it.
  defp link(conn, actor, %{router: router, help: help}) do
    with %{} <- actor,
         [segment | _] <- conn.path_info,
         type when is_binary(type) <- type_for(router, segment),
         true <- Help.visible?(actor, router, type) do
      "#{help}/#{type}"
    else
      _ -> help
    end
  end

  defp type_for(router, segment) do
    for domain <- router.domains(),
        resource <- Ash.Domain.Info.resources(domain),
        type = Samen.Scope.ApiKey.json_api_type(resource),
        type != nil,
        route <- apply(Module.concat(["AshJsonApi", "Resource", "Info"]), :routes, [resource]) || [],
        String.split(route.route, "/", trim: true) |> List.first() == segment do
      type
    end
    |> List.first()
  end

  defp no_scopes?(%{api_key: %{} = key}), do: key |> Map.get(:scopes) |> then(&(not is_map(&1) or &1 == %{}))
  defp no_scopes?(_), do: false

  defp vnd_api?(conn), do: conn |> get_resp_header("content-type") |> Enum.any?(&String.starts_with?(&1, "application/vnd.api+json"))

  # `resp_body` is iodata for a response sent with a body; a file or chunked response has none to rewrite.
  defp decode(body) when is_binary(body) or is_list(body), do: Jason.decode(IO.iodata_to_binary(body))
  defp decode(_body), do: :error
end
