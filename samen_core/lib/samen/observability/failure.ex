defmodule Samen.Observability.Failure do
  @moduledoc """
  The kernel's ONE value-free failure report (honest-reads, kernel phase). A read, probe or side
  effect that failed and is handled by its caller (fail closed, fall back, retry later) says so
  here instead of vanishing into `rescue _ -> []`: one `Logger.error` line and one telemetry
  event, carrying the NAME of the operation, the org id (a canonical UUID or a fixed
  placeholder) and the exception MODULE names — never the exception message or struct, the
  query, a row value, a vault token or a raw parameter (an Ash error interpolates the very
  values it was processing, so it is never `inspect`ed or `Exception.message`d here).

  `Samen.Web.Reads.Guard.report/3` delegates to `report/5`; kernel code calls `report/3`.
  Returns `:ok` and never raises (observability must not break what it observes).

      Failure.report(:org_actor_resolve, org_id, e)
      #=> logs `[Samen.Core] read failed read=org_actor_resolve org=<uuid> cause=Ash.Error.Unknown`
  """
  require Logger

  @doc "Report a failed READ `name` (`scope`: a `Samen.Scope`, a map with `:org_id`, an org id, or anything)."
  @spec report(atom(), term(), term()) :: :ok
  def report(name, scope, reason), do: report(:read, name, scope, reason, [])

  @doc """
  Report a failure of `kind` (`:read` | `:write`). Options: `:tag` (log prefix, default
  `"[Samen.Core]"`) and `:event_prefix` (telemetry prefix, default `[:samen, :core]`; the event is
  `prefix ++ [kind, :error]`).
  """
  @spec report(:read | :write, atom(), term(), term(), keyword()) :: :ok
  def report(kind, name, scope, reason, opts) when kind in [:read, :write] and is_atom(name) do
    causes = causes(reason)
    tag = Keyword.get(opts, :tag, "[Samen.Core]")

    Logger.error("#{tag} #{kind} failed #{kind}=#{name} org=#{org_of(scope)} cause=#{Enum.join(causes, ",")}")

    emit(Keyword.get(opts, :event_prefix, [:samen, :core]), kind, name, causes)
  rescue
    _ -> :ok
  end

  @doc "The value-free cause names of `reason` (exception module plus its inner error modules)."
  @spec causes(term()) :: [String.t()]
  def causes(%{__struct__: module} = e) do
    inner =
      case e do
        %{errors: errors} when is_list(errors) -> Enum.map(errors, &module_name/1)
        _ -> []
      end

    Enum.uniq([module_name(module) | inner])
  end

  def causes(kind) when is_atom(kind), do: [Atom.to_string(kind)]
  def causes(_other), do: ["unknown"]

  defp module_name(%{__struct__: module}), do: module_name(module)
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_), do: "unknown"

  defp org_of(%{actor: %{org_id: org_id}}) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(%{org_id: org_id}) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(org_id) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(_), do: "unknown"

  # The org id may come straight from a URL or param: only a canonical UUID reaches the log line, anything
  # else (newlines, `cause=` forgeries, megabytes) is a fixed placeholder, so a caller cannot inject a fake
  # log line. (`Ecto.UUID.cast/1` alone also accepts a raw 16-byte binary.)
  defp safe_org(org_id) when byte_size(org_id) == 36 do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> uuid
      :error -> "invalid"
    end
  end

  defp safe_org(_), do: "invalid"

  # Bounded pair `<kind>` + `cause` (no org id — a forbidden metric dimension, see `Samen.Metrics`).
  defp emit(prefix, kind, name, causes) do
    :telemetry.execute(prefix ++ [kind, :error], %{count: 1}, %{kind => name, cause: List.first(causes)})
  rescue
    _ -> :ok
  end
end
