defmodule Samen.Identity.SlugFree do
  @moduledoc """
  `Identity.Org` validation (`:create`, `:update` and `:open_account`): a slug being SET must not already be taken, either as
  another org's `slug` (compared trimmed and case-insensitively) or as another org's `id`. An update that leaves the org's own slug as it is is not checked, and an update never collides with the org's own row.

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
        slug when is_binary(slug) and slug != "" ->
          if changing?(changeset), do: check(changeset, slug), else: changeset

        _ ->
          changeset
      end
    end)
  end

  # An update that leaves the slug as it is has nothing to check (the org holds its own slug). A create, or an
  # update that sets a different slug, is checked against every OTHER org.
  defp changing?(%{action_type: :update} = changeset), do: Ash.Changeset.changing_attribute?(changeset, :slug)
  defp changing?(_changeset), do: true

  defp check(changeset, slug) do
    resource = changeset.resource
    # compared trimmed and case-insensitively on BOTH sides, so `Acme` / ` acme ` collide with `acme`. Stored slugs
    # are not rewritten and no format is imposed: this only widens what counts as "the same slug".
    normalized = slug |> String.trim() |> String.downcase()

    query =
      case Ecto.UUID.cast(normalized) do
        {:ok, uuid} ->
          Ash.Query.filter(resource, fragment("lower(regexp_replace(?, '^\\s+|\\s+$', '', 'g'))", slug) == ^normalized or id == ^uuid)

        :error ->
          Ash.Query.filter(resource, fragment("lower(regexp_replace(?, '^\\s+|\\s+$', '', 'g'))", slug) == ^normalized)
      end

    # An update never collides with the org's OWN row (its slug, or its id used as its slug), whether or not `slug`
    # is loaded on the record in hand: the id is always there. Another org's id is still refused.
    query =
      case changeset do
        %{action_type: :update, data: %{id: id}} when not is_nil(id) -> Ash.Query.filter(query, id != ^id)
        _ -> query
      end

    # authz-scope: uniqueness probe over ALL orgs (a collision with another tenant's row must be visible to be refused); boolean only
    case Ash.exists(query, authorize?: false) do
      {:ok, false} -> changeset
      {:ok, true} -> Ash.Changeset.add_error(changeset, field: :slug, message: "is already taken")
      {:error, _} -> Ash.Changeset.add_error(changeset, field: :slug, message: "could not be checked")
    end
  end
end
