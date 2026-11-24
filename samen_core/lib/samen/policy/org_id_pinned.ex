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
      action makes). Sending the value the row already has passes only when the record in hand has
      `org_id` loaded (it is not selected by default): with it NotLoaded the pin cannot tell the
      value is unchanged, so the write is refused. Load it (`Ash.load!(record, :org_id)`) to send it back.
    * **create** — when an actor with an `org_id` creates a row, the row's `org_id` must be that
      actor's own. (The actor-less / org-less seed and system paths are not actor writes.) An
      **upsert** that would rewrite `org_id` on a conflicting row only updates a row of the actor's
      own org (an upsert condition) unless `org_id` is part of the identity it conflicts on:
      otherwise the actor's own `org_id` would be written over ANOTHER org's row that merely shares
      the key. An upsert onto a foreign row does not update it.

  Both checks apply only to an AUTHORIZED write (`authorize?` is not `false`): code that runs
  with `authorize?: false` is trusted system code and keeps its sanctioned seed path
  (`force_change_attribute`, `Ash.Seed`).

  ## Build time and action time

  The check runs when the changeset is built (so a bad write is refused early) AND again, always, in a
  `before_action` that reads the authorization the action actually RUNS with
  (`changeset.context.private.authorize?`, which `Ash.update(..., authorize?: x)` sets). So:

    * built with `authorize?: false` and run authorized: pinned at run time;
    * built normally and run with `authorize?: false` (the `Samen.Notifications.Digest` pattern):
      system code at run time, nothing re-checked then; an `org_id` change on such a changeset is
      still an error from the build, so the pattern behaves exactly as before.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> then(&if(applies?(context), do: check(&1, context), else: &1))
    |> Changeset.before_action(&recheck/1)
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

  # At action time: the authorization the action runs with, as Ash records it on the changeset.
  defp recheck(changeset) do
    if changeset.context[:private][:authorize?] != false do
      changeset |> check(%{}) |> check_upsert()
    else
      changeset
    end
  end

  # An upsert writes its `upsert_fields` over the row it conflicts with. If `org_id` is among them and is not
  # part of the conflict key, the row it lands on can belong to any org: the actor's own `org_id` would be written
  # over ANOTHER org's row that merely shares the key. The write is made to apply to the actor's own rows only, as
  # an upsert condition on the stored row (`WHERE org_id = <actor org>` on the conflict update): an upsert onto a
  # row of the actor's own org is unchanged, onto a foreign row it does not update (nothing of that row changes).
  defp check_upsert(%{action_type: :create} = changeset) do
    private = changeset.context[:private] || %{}

    with true <- upsert?(changeset, private),
         true <- writes_org_on_conflict?(changeset, private),
         false <- :org_id in conflict_keys(changeset, private),
         %{org_id: org} when is_binary(org) <- actor_of(changeset) do
      Changeset.filter(changeset, Ash.Expr.expr(org_id == ^org))
    else
      _ -> changeset
    end
  end

  defp check_upsert(changeset), do: changeset

  defp actor_of(changeset), do: actor(%{}, changeset)

  # `private.upsert?` is set on EVERY create at run time (Ash records it unconditionally), so it cannot tell an
  # upsert from a plain create. An upsert is an action declared `upsert?`, or a run that names the identity it
  # conflicts on (`upsert_identity:`). A run-option upsert on the primary key alone cannot be told from a create.
  defp upsert?(changeset, private), do: changeset.action.upsert? == true or private[:upsert_identity] != nil

  defp writes_org_on_conflict?(changeset, private) do
    case private[:upsert_fields] do
      fields when is_list(fields) -> :org_id in fields
      _ -> Changeset.changing_attribute?(changeset, :org_id)
    end
  end

  defp conflict_keys(changeset, private) do
    case private[:upsert_identity] &&
           Ash.Resource.Info.identity(changeset.resource, private[:upsert_identity]) do
      %{keys: keys} -> keys
      _ -> Ash.Resource.Info.primary_key(changeset.resource)
    end
  end

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
