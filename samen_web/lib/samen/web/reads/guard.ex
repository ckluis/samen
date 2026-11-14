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

  A WRITE uses `write/3` (below): its own tagged return passes through, an exception — or a RETURNED
  `{:error, %Ash.Error.Unknown{} | %Ash.Error.Framework{}}`, which is how a non-bang Ash write reports a
  data-layer outage — becomes `{:error, :unavailable}` (logged by name as a WRITE failure), and the screen
  tells the user — see cookbook Recipe 11. A returned `Invalid` / `Forbidden` is a real refusal and passes through.

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
  event (a failed write: `write failed write=<name>` and `[:samen, :web, :write, :error]`). The log carries the read's NAME, the org id and the exception MODULE names
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
  honest `{:error, :not_configured}`, a changeset error (`Ash.Error.Invalid`), a returned
  `Ash.Error.Forbidden`, `:ok` — with two exceptions that are an OUTAGE, not a refusal:

    * an exception or exit becomes `{:error, :unavailable}` (an `Ash.Error.Forbidden` raise becomes
      `{:error, :forbidden}`);
    * a RETURNED `{:error, %Ash.Error.Unknown{}}` or `{:error, %Ash.Error.Framework{}}` becomes
      `{:error, :unavailable}`. A non-bang Ash write does not raise on a data-layer failure — it
      returns the wrapped driver error — so without this a database outage reached the screen as
      "Revoke refused (admin role required…)": denial copy for an outage.

  The failure is reported as a failed WRITE (one `Logger.error` line `write failed write=<name>` and
  one `[:samen, :web, :write, :error]` telemetry event, by name and exception module only), so the
  caller can tell the user with value-free copy and no exception term ever reaches a template. The
  same test seam (`inject_faults/1`) fails a named write through this path.
  """
  @spec write(atom(), term(), (-> t)) :: t | {:error, failure()} when t: term()
  def write(name, scope, fun) when is_atom(name) and is_function(fun, 0) do
    maybe_inject(name)

    case fun.() do
      {:error, %Ash.Error.Unknown{} = e} -> write_failed(name, scope, e)
      {:error, %Ash.Error.Framework{} = e} -> write_failed(name, scope, e)
      other -> other
    end
  rescue
    e -> write_failed(name, scope, e)
  catch
    :exit, _reason -> write_failed(name, scope, :exit)
    :throw, _value -> write_failed(name, scope, :throw)
  end

  defp write_failed(_name, _scope, %Ash.Error.Forbidden{}), do: {:error, :forbidden}

  defp write_failed(name, scope, reason) do
    log_failure(:write, name, scope, reason)
    {:error, :unavailable}
  end

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

  @doc """
  Submit an `AshPhoenix.Form` as the write called `name` (cookbook Recipe 11) and classify the outcome:

    * `{:ok, record}` — saved;
    * `{:error, form}` — a REAL refusal (validation / policy changeset errors): the form re-renders with its field
      errors, unchanged from calling `AshPhoenix.Form.submit/2` directly;
    * `{:error, :unavailable}` — the write itself failed. A data-layer outage reaches a form as an
      `Ash.Error.Unknown` / `Ash.Error.Framework` on its changeset, which the field errors would render as a validation
      message ("is invalid") — it is an outage (logged by name and exception module, nothing saved), so the screen
      says "couldn't save — nothing was saved, try again" via `write_copy/2`;
    * `{:error, :forbidden}` — an `Ash.Error.Forbidden`: denial copy, not field errors.

  A DB constraint the resource does not map (a foreign key, a unique index) also arrives as an `Ash.Error.Unknown`: that
  is a refusal retrying never fixes, so declare the constraint on the resource (`references`/`identity` with an
  `error_message`) and it surfaces as a field error instead of this outage.
  """
  @spec submit_form(atom(), term(), term(), map()) :: {:ok, term()} | {:error, term()}
  def submit_form(name, scope, form, params) when is_atom(name) do
    write(name, scope, fn ->
      case AshPhoenix.Form.submit(form, params: params) do
        {:error, failed} = error ->
          case form_failure_class(failed) do
            %Ash.Error.Unknown{} = class -> {:error, class}
            %Ash.Error.Framework{} = class -> {:error, class}
            %Ash.Error.Forbidden{} -> {:error, :forbidden}
            _ -> error
          end

        other ->
          other
      end
    end)
  end

  defp form_failure_class(%Phoenix.HTML.Form{source: source}), do: form_failure_class(source)

  defp form_failure_class(%AshPhoenix.Form{source: %{errors: errors}}) when errors != [],
    do: Ash.Error.to_error_class(errors)

  defp form_failure_class(_), do: nil

  @doc """
  Split a `result/1` into `{value, error}` for one pane: `{value, nil}`, or `{default, :unavailable | :forbidden}`.
  """
  @spec pane(result(t), t) :: {t, failure() | nil} when t: term()
  def pane({:ok, value}, _default), do: {value, nil}
  def pane({:error, kind}, default), do: {default, kind}

  @doc "Value-free copy for a failed pane read: outage copy, or denial copy for `:forbidden`."
  @spec error_body(failure() | true) :: String.t()
  def error_body(:forbidden), do: "You don't have access to view this."
  def error_body(_kind), do: message()

  @doc "The retry event for a failed pane read: none for a denial (retrying will not help)."
  @spec retry_event(failure() | true, String.t()) :: String.t() | nil
  def retry_event(:forbidden, _event), do: nil
  def retry_event(_kind, event), do: event

  @doc """
  Value-free copy for a failed WRITE of kind `kind` (`write/3` / `submit_form/4`): "Couldn't <what> right now.
  Nothing was changed — try again." for an outage, "You don't have permission to <what>." for a denial.
  """
  @spec write_copy(failure() | true, String.t()) :: String.t()
  def write_copy(:forbidden, what), do: "You don't have permission to #{what}."
  def write_copy(_kind, what), do: "Couldn't #{what} right now. Nothing was changed — try again."

  @doc """
  Cast a client-supplied id to a canonical UUID: `{:ok, uuid}` or `{:error, :not_found}` — a malformed id is "not
  found" (no query, no error log), never an outage.
  """
  @spec cast_id(term()) :: {:ok, String.t()} | {:error, :not_found}
  def cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  def cast_id(_), do: {:error, :not_found}

  @doc "The first row of a successful read as `{:ok, row}`, or `{:error, :not_found}` — an honest absence."
  @spec first_or_not_found([t]) :: {:ok, t} | {:error, :not_found} when t: term()
  def first_or_not_found([row | _]), do: {:ok, row}
  def first_or_not_found(_), do: {:error, :not_found}

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

  @doc """
  The copy for a failed read of kind `kind` (`:unavailable` / `true` / anything else is the outage copy;
  `:forbidden` is DENIAL copy — a denial is not an outage, retrying will not help, and the screen must not
  say "Nothing was lost — try again").
  """
  @spec message(failure() | true) :: String.t()
  def message(:forbidden), do: "Your operator role may not view this."
  def message(_kind), do: message()

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
  def report(name, scope, reason) when is_atom(name), do: log_failure(:read, name, scope, reason)

  defp log_failure(kind, name, scope, reason) do
    causes = causes(reason)

    Logger.error(
      "[Samen.Web.Reads] #{kind} failed #{kind}=#{name} org=#{org_of(scope)} cause=#{Enum.join(causes, ",")}"
    )

    emit(kind, name, causes)
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

  defp org_of(%{actor: %{org_id: org_id}}) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(%{org_id: org_id}) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(org_id) when is_binary(org_id), do: safe_org(org_id)
  defp org_of(_), do: "unknown"

  # The org id may come straight from a URL or param (a drill-in's `:org_id`): only a canonical UUID reaches
  # the log line, anything else (newlines, `cause=` forgeries, megabytes) is a fixed placeholder, so a caller
  # cannot inject a fake log line. (`Ecto.UUID.cast/1` alone also accepts a raw 16-byte binary.)
  defp safe_org(org_id) when byte_size(org_id) == 36 do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> uuid
      :error -> "invalid"
    end
  end

  defp safe_org(_), do: "invalid"

  # Reads keep `[:samen, :web, :read, :error]` (`read`, `cause`); a failed write has its own
  # `[:samen, :web, :write, :error]` (`write`, `cause`) so an outage dashboard never mixes the two.
  defp emit(kind, name, causes) do
    :telemetry.execute([:samen, :web, kind, :error], %{count: 1}, %{
      kind => name,
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
