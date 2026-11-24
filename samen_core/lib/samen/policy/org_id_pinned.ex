defmodule Samen.Policy.OrgIdPinned do
  @moduledoc """
  The tenant column is pinned by construction (identity-authz review 3, A).

  `org_id` is a public, writable core attribute, and `Samen.Policy.OrgScope` on an UPDATE
  filters the PRE-image only. Without this change every resource whose actions accept
  `org_id` (every `defaults([update: :*])` resource) let an in-org actor write the row into
  ANOTHER organisation, and a resource whose create policy does not bind `org_id` let an actor
  file a row under a foreign one.

  `Samen.Transformers.OrgIdPinned` adds this change to EVERY resource that has an `org_id`
  attribute, so no resource can be left out:

    * **update** — an authorized write may not change `org_id` (an input, or any change an
      action makes). Writing the value it already has is a no-op and passes.
    * **create** — when an actor with an `org_id` creates a row, the row's `org_id` must be that
      actor's own. (The actor-less / org-less seed and system paths are not actor writes.)

  Both checks apply only to an AUTHORIZED write (`authorize?` is not `false`): code that runs
  with `authorize?: false` is trusted system code and keeps its sanctioned seed path
  (`force_change_attribute`, `Ash.Seed`).
  """
  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, context) do
    if applies?(context) do
      changeset
      |> check(context)
      |> Changeset.before_action(&check(&1, context))
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, context) do
    if applies?(context) do
      case check(changeset, context) do
        %{valid?: false} = bad -> {:error, List.first(bad.errors)}
        _ -> :ok
      end
    else
      :ok
    end
  end

  @impl true
  def batch_change(changesets, opts, context),
    do: Enum.map(changesets, &change(&1, opts, context))

  defp applies?(context), do: context.authorize? != false

  defp check(%{action_type: :update} = changeset, _context) do
    if changing_org_id?(changeset) do
      Changeset.add_error(changeset,
        field: :org_id,
        message: "org_id cannot be changed: a record stays in the organisation it was created in"
      )
    else
      changeset
    end
  end

  defp check(%{action_type: :create} = changeset, context) do
    with %{org_id: actor_org} when is_binary(actor_org) <- actor(context, changeset),
         row_org when not is_nil(row_org) <- Changeset.get_attribute(changeset, :org_id),
         true <- to_string(row_org) != actor_org do
      Changeset.add_error(changeset,
        field: :org_id,
        message: "org_id must be the acting organisation's own: a row cannot be created in another organisation"
      )
    else
      _ -> changeset
    end
  end

  defp check(changeset, _context), do: changeset

  defp actor(%{actor: actor}, _changeset) when is_map(actor), do: actor
  defp actor(_context, %{context: %{private: %{actor: actor}}}) when is_map(actor), do: actor
  defp actor(_, _), do: nil

  defp changing_org_id?(changeset) do
    Changeset.changing_attribute?(changeset, :org_id) or
      Keyword.has_key?(List.wrap(changeset.atomics), :org_id)
  end
end
