defmodule Samen.Identity.SlugFree do
  @moduledoc """
  `Identity.Org :open_account` validation: the new account's `slug` must not already be taken, either as another
  org's `slug` or as another org's `id`.

  An account's slug is how a host names the tenant it stands for (driftwood's `Directory.orgs/0` keys the
  workspace switcher by slug), so a second row carrying an existing tenant's slug or id would render a forged name
  under that tenant. A blank slug is left alone.

  The uniqueness probe is a bare existence check over the whole org table (it must SEE rows of every org to refuse
  a collision, so it cannot run under the actor's org filter) and returns only a boolean refusal. A probe that
  FAILS refuses the write (fail closed): an unverifiable slug is not a free one.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :slug) do
        slug when is_binary(slug) and slug != "" -> check(changeset, slug)
        _ -> changeset
      end
    end)
  end

  defp check(changeset, slug) do
    resource = changeset.resource

    query =
      case Ecto.UUID.cast(slug) do
        {:ok, uuid} -> Ash.Query.filter(resource, slug == ^slug or id == ^uuid)
        :error -> Ash.Query.filter(resource, slug == ^slug)
      end

    # authz-scope: uniqueness probe over ALL orgs (a collision with another tenant's row must be visible to be refused); boolean only
    case Ash.exists?(query, authorize?: false) do
      false -> changeset
      true -> Ash.Changeset.add_error(changeset, field: :slug, message: "is already taken")
      _ -> Ash.Changeset.add_error(changeset, field: :slug, message: "could not be checked")
    end
  end
end
