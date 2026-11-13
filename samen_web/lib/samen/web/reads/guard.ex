defmodule Samen.Web.Reads.Guard do
  @moduledoc """
  The ONE read-failure convention for `samen_web` (WP6 phase 1; ADR-052 observability).

  A read helper that ends in `rescue _ -> []` renders a database outage, a decrypt failure
  or a bug as "No contacts yet — create your first contact": HTTP 200, nothing logged, and
  on some screens an empty-state CTA that then creates duplicates. This module makes a
  failed read DISTINGUISHABLE from an empty one at the call site, and records the failure
  once, safely.

  ## Shape

      Guard.run(:crm_contacts_for_company, scope, fn -> ...Ash.read!... end)
      #=> {:ok, value} | {:error, :unavailable} | {:error, :forbidden}

    * `{:ok, value}` — the read ran. An empty `value` is an HONEST empty.
    * `{:error, :unavailable}` — the read raised or exited (outage, decrypt failure, bug).
      The screen shows the kit `error_state/1`, never an empty state, never "not found".
    * `{:error, :forbidden}` — an authorization denial (`Ash.Error.Forbidden`). A denial
      stays a denial: it is NOT logged as a failure and NOT shown as an outage; a screen
      treats it exactly as it always did (nothing to show / not found).

  Honest outcomes that are not exceptions — `{:error, :not_configured}`,
  `{:error, :not_implemented}` (the fail-honest adapter contract), a missing record — are
  ordinary return values of the function inside `run/3` and pass through untouched as
  `{:ok, _}`. Only an exception or exit becomes `:unavailable`.

  A WRITE uses `write/3` (below): its own tagged return passes through, an exception becomes
  `{:error, :unavailable}` (logged by name), and the screen tells the user — see cookbook Recipe 11.

  ## Adopting it with a small diff

  A read keeps its name and its legacy return shape (so existing callers are unchanged) and
  gains a tagged sibling:

      def contacts_for_company(mount, scope, id),
        do: mount |> contacts_for_company_result(scope, id) |> Guard.value([])

      def contacts_for_company_result(mount, scope, id),
        do: Guard.run(:crm_contacts_for_company, scope, fn -> ... end)

  A page read (`(mount, scope, %ListState{}) -> %Page{}`) uses `page/4`, which returns an
  EMPTY page with `error: :unavailable` on failure — the shape `Samen.Web.ListLive`
  already consumes.

  ## What is logged (and what never is)

  One `Logger.error` line per failure and one `[:samen, :web, :read, :error]` telemetry
  event. The log carries the read's NAME, the org id and the exception MODULE names
  (`Ash.Error.Unknown`, `DBConnection.ConnectionError`, …). It never carries the
  exception's message or struct, the query, row data, a vault token or any parameter: an
  Ash error interpolates the very values being processed, so it is never `inspect`ed or
  `Exception.message`d here. The telemetry metadata is the bounded pair `read` +
  `cause` (no org id — a forbidden metric dimension, see `Samen.Metrics`).

  ## Test seam

  With `config :samen_web, :read_fault_seam, true` (samen_web's own `config/test.exs` only)
  `inject_faults/1` makes the named reads raise `Samen.Web.Reads.Guard.InjectedFault`
  through this same path, and `clear_faults/0` restores them. In every other build the seam
  is compiled out and `inject_faults/1` returns `{:error, :seam_disabled}`.
  """

  require Logger

  alias Samen.Web.Page

  @typedoc "Why a read produced no value."
  @type failure :: :unavailable | :forbidden
  @type result(t) :: {:ok, t} | {:error, failure()}

  @seam Application.compile_env(:samen_web, :read_fault_seam, false)

  defmodule InjectedFault do
    @moduledoc "Raised by the test fault seam; never raised outside samen_web's own test env."
    defexception message: "injected read fault"
  end

  @doc """
  Run `fun` as the read called `name`. `scope` is the acting `Samen.Scope` (or an org id)
  and is used only to name the org in the failure log.
  """
  @spec run(atom(), term(), (-> t)) :: result(t) when t: term()
  def run(name, scope, fun) when is_atom(name) and is_function(fun, 0) do
    maybe_inject(name)
    {:ok, fun.()}
  rescue
    e -> failed(name, scope, e)
  catch
    :exit, _reason -> failed(name, scope, :exit)
    :throw, _value -> failed(name, scope, :throw)
  end

  @doc """
  Run a WRITE (or any action that returns its own `{:ok, _} | {:error, _}` / `:ok`) as the action
  called `name` (WP6 phase 2). The function's own return value passes through UNTOUCHED — an
  honest `{:error, :not_configured}`, a changeset error, `:ok` — and only an exception or exit
  becomes `{:error, :unavailable}` (an `Ash.Error.Forbidden` raise becomes `{:error, :forbidden}`).
  The failure is reported exactly like a failed read (one `Logger.error` + telemetry event, by
  name and exception module only), so the caller can tell the user with value-free copy and no
  exception term ever reaches a template. The same test seam (`inject_faults/1`) fails a named
  write through this path.
  """
  @spec write(atom(), term(), (-> t)) :: t | {:error, failure()} when t: term()
  def write(name, scope, fun) when is_atom(name) and is_function(fun, 0) do
    maybe_inject(name)
    fun.()
  rescue
    e -> write_failed(name, scope, e)
  catch
    :exit, _reason -> write_failed(name, scope, :exit)
    :throw, _value -> write_failed(name, scope, :throw)
  end

  defp write_failed(name, scope, reason), do: failed(name, scope, reason)

  @doc """
  Run a page read. `fun` returns a `%Samen.Web.Page{}`; on failure the result is an EMPTY page
  (never unbounded) with `error: :unavailable`. A denial yields a plain empty page.
  """
  @spec page(atom(), term(), Samen.Web.ListState.t(), (-> Page.t())) :: Page.t()
  def page(name, scope, state, fun) do
    case run(name, scope, fun) do
      {:ok, %Page{} = page} -> page
      {:error, kind} -> failed_page(state, kind)
    end
  end

  @doc "The empty page a failed read returns (`error: :unavailable` unless it was a denial)."
  @spec failed_page(map(), failure()) :: Page.t()
  def failed_page(state, kind) do
    %Page{
      items: [],
      page_size: Samen.Web.Reads.bounded_page_size(Map.get(state, :page_size)),
      error: if(kind == :unavailable, do: :unavailable)
    }
  end

  @doc "The legacy value of a result: the value, or `default` for any error (compat shims)."
  @spec value(result(t), t) :: t when t: term()
  def value({:ok, value}, _default), do: value
  def value({:error, _kind}, default), do: default

  @doc "True only for a genuine failure (an outage), not for a denial or a value."
  @spec unavailable?(term()) :: boolean()
  def unavailable?({:error, :unavailable}), do: true
  def unavailable?(%Page{error: :unavailable}), do: true
  def unavailable?(_), do: false

  @doc "The generic, value-free copy every read-failure state shows."
  @spec message() :: String.t()
  def message, do: "We couldn't load this right now. Nothing was lost — try again."

  # -- failure handling ----------------------------------------------------------

  defp failed(_name, _scope, %Ash.Error.Forbidden{}), do: {:error, :forbidden}

  defp failed(name, scope, reason) do
    report(name, scope, reason)
    {:error, :unavailable}
  end

  @doc """
  Record a failure that the caller handles itself (e.g. a PII resolver that falls back to the
  still-masked records): the same one log line + telemetry event as a failed `run/3`, nothing
  else. Returns `:ok`. `reason` is the exception (or `:exit` / `:throw`).
  """
  @spec report(atom(), term(), term()) :: :ok
  def report(name, scope, reason) when is_atom(name) do
    causes = causes(reason)

    Logger.error(
      "[Samen.Web.Reads] read failed read=#{name} org=#{org_of(scope)} cause=#{Enum.join(causes, ",")}"
    )

    emit(name, causes)
  end

  # Module names only — never the exception message or struct (it interpolates row values).
  defp causes(%{__struct__: module} = e) do
    inner =
      case e do
        %{errors: errors} when is_list(errors) -> Enum.map(errors, &module_name/1)
        _ -> []
      end

    Enum.uniq([module_name(module) | inner])
  end

  defp causes(kind) when is_atom(kind), do: [Atom.to_string(kind)]

  defp module_name(%{__struct__: module}), do: module_name(module)
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_), do: "unknown"

  defp org_of(%{actor: %{org_id: org_id}}) when is_binary(org_id), do: org_id
  defp org_of(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp org_of(org_id) when is_binary(org_id), do: org_id
  defp org_of(_), do: "unknown"

  defp emit(name, causes) do
    :telemetry.execute([:samen, :web, :read, :error], %{count: 1}, %{
      read: name,
      cause: List.first(causes)
    })
  rescue
    _ -> :ok
  end

  # -- test seam -----------------------------------------------------------------

  if @seam do
    @doc "Make the named reads (a list of names, or `:all`) fail. Test env only."
    @spec inject_faults([atom()] | :all) :: :ok
    def inject_faults(names), do: Application.put_env(:samen_web, :read_faults, names)

    @doc "Remove every injected fault."
    @spec clear_faults() :: :ok
    def clear_faults, do: Application.delete_env(:samen_web, :read_faults)

    defp maybe_inject(name) do
      case Application.get_env(:samen_web, :read_faults) do
        :all -> raise InjectedFault
        names when is_list(names) -> if name in names, do: raise(InjectedFault)
        _ -> :ok
      end
    end
  else
    @doc false
    @spec inject_faults([atom()] | :all) :: {:error, :seam_disabled}
    def inject_faults(_names), do: {:error, :seam_disabled}

    @doc false
    def clear_faults, do: :ok

    defp maybe_inject(_name), do: :ok
  end
end
