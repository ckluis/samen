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
  """

  @org_a "00000000-0000-4000-8000-00000000000a"
  @org_b "00000000-0000-4000-8000-00000000000b"

  @type report :: %{
          walked: non_neg_integer(),
          no_org_id: [module()],
          actions: non_neg_integer(),
          violations: [{module(), atom(), atom(), String.t()}],
          unexercisable: [{module(), atom(), term()}],
          exceptions: %{module() => String.t()}
        }

  @spec walk([module()], %{module() => String.t()}) :: report()
  def walk(domains, exceptions \\ %{}) do
    resources =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()

    {with_org, without_org} =
      Enum.split_with(resources, &Ash.Resource.Info.attribute(&1, :org_id))

    results = Enum.flat_map(with_org, &exercise/1)

    violations =
      for {:violation, r, a, t, msg} <- results, not Map.has_key?(exceptions, r), do: {r, a, t, msg}

    unexercisable = for {:unexercisable, r, a, why} <- results, do: {r, a, why}

    %{
      walked: length(with_org),
      no_org_id: without_org,
      actions: Enum.count(results, &match?({:ok, _, _, _}, &1)) + length(violations),
      violations: violations,
      unexercisable: unexercisable,
      exceptions: exceptions
    }
  end

  defp exercise(resource) do
    actor = %{id: Ash.UUID.generate(), org_id: @org_a, role: :owner, verified?: true, kind: :tenant, plane: :tenant}

    for action <- Ash.Resource.Info.actions(resource), action.type in [:create, :update] do
      try do
        changeset = build(resource, action, actor)

        if carries_foreign_org?(changeset) and not org_error?(changeset) do
          {:violation, resource, action.name, action.type, "the changeset carries org_id #{@org_b}"}
        else
          {:ok, resource, action.name, action.type}
        end
      rescue
        e -> {:unexercisable, resource, action.name, Exception.message(e)}
      end
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

  defp org_error?(changeset) do
    Enum.any?(changeset.errors, fn e -> Map.get(e, :field) == :org_id or Map.get(e, :fields) == [:org_id] end)
  end
end
