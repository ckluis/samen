defmodule Samen.OrgIdPinnedGuard do
  @moduledoc """
  The verifier-style walk behind the "org_id is pinned" guard test (`Samen.Policy.OrgIdPinned`).

  `walk/1` takes a host's Ash domains and, for EVERY resource of every domain and every one of
  its update and create actions, builds the changeset an authorized in-org actor would build:

    * **update** — `org_id: <another org>` as an input against a record that lives in the
      actor's org. The resource passes when the changeset refuses it (an `org_id` error) or does
      not carry the new `org_id` at all. It FAILS when the changeset would write the foreign org.
    * **create** — `org_id: <another org>` as an input. Same rule: refused, or not carried.

  Fail-closed: a walk that visits no resource is an error; a resource whose action cannot be
  built (the changeset raises) is reported by name as `:unexercisable` — never skipped. A
  resource with no `org_id` attribute at all has nothing to move and is listed under
  `:no_org_id`. A host may declare an `exceptions` map (`%{Resource => "reason"}`) for a resource that
  legitimately needs a mutable `org_id`; every exception is carried in the report.

  ## The walk needs no database

  Building a changeset is not running an action: nothing it does may touch the database. A `change`
  that queries at build time rides on whatever sandbox owner is shared at that moment (and dies with
  it — the CI flake), and Ash turns a failed query into a changeset error that looks like validation.
  So the walk treats ANY of these as `:unexercisable`, by resource and action, never as exercised:
  a build that exits or raises, a changeset error that is an unexpected exception (Ash's
  `Unknown` class — a swallowed crash) and a query on a watched repo issued by the walking process
  or by a process it started (`$callers`, e.g. a `Task`).

  The watched repos are DERIVED from the walked resources' data layer (the read and the mutate repo of
  every Postgres-backed resource), united with any `repos:` the host passes. There is no way to turn the
  watch off by leaving `repos:` out; a Postgres-backed resource whose repo cannot be resolved raises, by
  resource name.

  ## The blind spot of moving a check into `before_action`

  A check that needs the database must run in a `before_action` hook, not at build time. The price: an
  action that SETS `org_id` inside such a hook (it takes the org as an ARGUMENT named `org_id` and copies it
  into the row, as `Marketing`'s `Send.:create_checked` does) has no `org_id` on the changeset the walk
  builds, so the walk cannot see the pin at all — it only works because of the hook ORDER (the action's
  hook runs before the global `Samen.Policy.OrgIdPinned` recheck). Such an action is NOT counted as
  exercised. The walk detects it (an `org_id` argument the changeset did not carry as an attribute) and
  reports it under `:hook_set`; the host must list it in `hook_set:` with a reason and the NAMED behavioural
  test that proves a foreign org is refused (`%{{Resource, :action} => %{reason:, test_file:, test_name:}}`).
  The walk then fails (`:hook_set_unlisted`) for a detected action that is not listed, and
  (`:hook_set_unproven`) for a listed one whose test file does not contain that test name or whose action
  does not exist. A hook-set pin that does not take an `org_id` argument (any other shape) cannot be
  detected statically: do not write one — take the org as an `org_id` argument so the walk sees it.
  """

  @org_a "00000000-0000-4000-8000-00000000000a"
  @org_b "00000000-0000-4000-8000-00000000000b"

  @type report :: %{
          walked: non_neg_integer(),
          no_org_id: [module()],
          actions: non_neg_integer(),
          violations: [{module(), atom(), atom(), String.t()}],
          unexercisable: [{module(), atom(), term()}],
          exceptions: %{module() => String.t()},
          hook_set: [{module(), atom()}],
          hook_set_unlisted: [{module(), atom()}],
          hook_set_unproven: [{module(), atom(), String.t()}],
          watched_repos: [module()]
        }

  @doc """
  Walk `domains`. Options: `repos:` (extra repos to watch, united with the derived ones) and `hook_set:`
  (see the moduledoc).
  """
  @spec walk([module()], %{module() => String.t()}, keyword()) :: report()
  def walk(domains, exceptions \\ %{}, opts \\ []) do
    resources = resources_of(domains)
    repos = Enum.uniq(derive_repos(resources) ++ Keyword.get(opts, :repos, []))
    handler = attach_query_watch(repos)

    try do
      do_walk(resources, exceptions, Keyword.get(opts, :hook_set, %{}))
      |> Map.put(:watched_repos, repos)
    after
      detach_query_watch(handler)
    end
  end

  defp resources_of(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
  end

  # The read and mutate repo of every Postgres-backed resource. A Postgres resource with no resolvable repo
  # would be walked with its queries unwatched: fail by name instead.
  defp derive_repos(resources) do
    resources
    |> Enum.filter(&(Ash.Resource.Info.data_layer(&1) == AshPostgres.DataLayer))
    |> Enum.flat_map(fn resource ->
      found =
        for type <- [:read, :mutate], repo = AshPostgres.DataLayer.Info.repo(resource, type), is_atom(repo), repo != nil,
            do: repo

      if found == [] do
        raise ArgumentError,
              "Samen.OrgIdPinnedGuard: #{inspect(resource)} is Postgres-backed but no repo could be resolved " <>
                "for it, so the walk would not watch its queries"
      end

      found
    end)
    |> Enum.uniq()
  end

  # Query events are emitted in the process that issues the query, so a handler that forwards only
  # events from the walking process sees exactly the queries the walk caused (not a concurrent test's).
  defp attach_query_watch(repos) do
    walker = self()
    id = {__MODULE__, make_ref()}

    events =
      Enum.uniq(
        for repo <- repos do
          prefix = Keyword.get(repo.config(), :telemetry_prefix, [])
          prefix ++ [:query]
        end
      )

    if events != [] do
      :ok =
        :telemetry.attach_many(
          id,
          events,
          fn _event, _measurements, meta, _config ->
            if self() == walker or walker in List.wrap(Process.get(:"$callers")),
              do: send(walker, {:org_pin_walk_query, meta[:query]})
          end,
          nil
        )
    end

    id
  end

  defp detach_query_watch(id), do: :telemetry.detach(id)

  defp do_walk(resources, exceptions, hook_set) do
    {with_org, without_org} =
      Enum.split_with(resources, &Ash.Resource.Info.attribute(&1, :org_id))

    results = Enum.flat_map(with_org, &exercise/1)

    violations =
      for {:violation, r, a, t, msg} <- results, not Map.has_key?(exceptions, r), do: {r, a, t, msg}

    unexercisable = for {:unexercisable, r, a, why} <- results, do: {r, a, why}

    detected = for {:hook_set, r, a} <- results, do: {r, a}
    {hook_set_unlisted, hook_set_unproven} = check_hook_set(resources, detected, hook_set)

    %{
      walked: length(with_org),
      no_org_id: without_org,
      actions: Enum.count(results, &match?({:ok, _, _, _}, &1)) + length(violations),
      violations: violations,
      unexercisable: unexercisable,
      exceptions: exceptions,
      hook_set: detected,
      hook_set_unlisted: hook_set_unlisted,
      hook_set_unproven: hook_set_unproven
    }
  end

  # Detected-but-unlisted, and listed-but-unproven (no such action, or the named test is not in the named file).
  defp check_hook_set(resources, detected, listed) do
    unlisted = Enum.reject(detected, &Map.has_key?(listed, &1))

    unproven =
      for {{resource, action} = key, entry} <- listed,
          why = unproven_reason(resources, key, entry),
          do: {resource, action, why}

    {unlisted, unproven}
  end

  defp unproven_reason(resources, {resource, action}, entry) do
    with true <- resource in resources or "the resource is not in the walked domains",
         true <- Ash.Resource.Info.action(resource, action) != nil or "the action does not exist",
         true <- is_binary(entry[:reason]) and entry[:reason] != "" or "no reason given",
         file when is_binary(file) <- entry[:test_file] || "no test_file given",
         {:ok, body} <- File.read(file) |> file_result(file),
         name when is_binary(name) <- entry[:test_name] || "no test_name given",
         true <- String.contains?(body, name) or "test #{inspect(name)} is not in #{file}" do
      nil
    else
      why when is_binary(why) -> why
      _ -> "unproven"
    end
  end

  defp file_result({:ok, body}, _file), do: {:ok, body}
  defp file_result(_, file), do: "test file #{file} is unreadable"

  defp exercise(resource) do
    actor = %{id: Ash.UUID.generate(), org_id: @org_a, role: :owner, verified?: true, kind: :tenant, plane: :tenant}

    for action <- Ash.Resource.Info.actions(resource), action.type in [:create, :update] do
      flush_queries()

      try do
        changeset = build(resource, action, actor)

        cond do
          (why = swallowed_crash(changeset)) != nil ->
            {:unexercisable, resource, action.name, why}

          (query = queried()) != nil ->
            {:unexercisable, resource, action.name, "the changeset build queried the database: #{inspect(query)}"}

          carries_foreign_org?(changeset) and not org_error?(changeset) ->
            {:violation, resource, action.name, action.type, "the changeset carries org_id #{@org_b}"}

          hook_set?(action, changeset) ->
            {:hook_set, resource, action.name}

          true ->
            {:ok, resource, action.name, action.type}
        end
      rescue
        e -> {:unexercisable, resource, action.name, Exception.message(e)}
      catch
        kind, reason -> {:unexercisable, resource, action.name, "#{kind}: #{inspect(reason)}"}
      end
    end
  end

  # Ash rescues a raise inside a change and stores it as an `Unknown`-class error on the changeset; a
  # failed query inside a change is such a raise (or an `{:error, _}` the change maps to validation, which
  # the query watch above catches). Either way the resource was NOT exercised.
  defp swallowed_crash(changeset) do
    Enum.find_value(changeset.errors, fn
      %Ash.Error.Unknown.UnknownError{} = e -> "a change crashed during the build: " <> Exception.message(e)
      _ -> nil
    end)
  end

  defp queried do
    receive do
      {:org_pin_walk_query, query} ->
        flush_queries()
        query || "<query>"
    after
      0 -> nil
    end
  end

  defp flush_queries do
    receive do
      {:org_pin_walk_query, _} -> flush_queries()
    after
      0 -> :ok
    end
  end

  defp build(resource, %{type: :update, name: name} = action, actor) do
    record = struct(resource, org_id: @org_a)
    record = %{record | __meta__: %{record.__meta__ | state: :loaded}}
    Ash.Changeset.for_update(record, name, inputs(resource, action), actor: actor, authorize?: true)
  end

  defp build(resource, %{type: :create, name: name} = action, actor) do
    Ash.Changeset.for_create(resource, name, inputs(resource, action), actor: actor, authorize?: true)
  end

  # The foreign org_id, plus a placeholder for every REQUIRED argument so an action whose changes
  # read an argument builds (the walk is about org_id, not the argument's meaning).
  defp inputs(_resource, action) do
    action.arguments
    |> Enum.reject(& &1.allow_nil?)
    |> Map.new(&{&1.name, placeholder(&1.type)})
    |> Map.put(:org_id, @org_b)
  end

  defp placeholder(type) do
    case Ash.Type.get_type(type) do
      Ash.Type.UUID -> Ash.UUID.generate()
      Ash.Type.Integer -> 1
      Ash.Type.Boolean -> true
      _ -> "placeholder"
    end
  end

  defp carries_foreign_org?(changeset) do
    Map.get(changeset.attributes, :org_id) == @org_b or
      Keyword.has_key?(List.wrap(changeset.atomics), :org_id)
  end

  # The org is taken as an ARGUMENT named `org_id` and the changeset carries no `org_id` attribute: the row's
  # org is set later, by a hook, so the build proves nothing about the pin.
  defp hook_set?(action, changeset) do
    Enum.any?(action.arguments, &(&1.name == :org_id)) and
      not Map.has_key?(changeset.attributes, :org_id)
  end

  defp org_error?(changeset) do
    Enum.any?(changeset.errors, fn e -> Map.get(e, :field) == :org_id or Map.get(e, :fields) == [:org_id] end)
  end
end
