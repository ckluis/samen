defmodule ReadScopeCorpus.Clean do
  require Ash.Query

  def pinned(resource, org_id) do
    resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end

  def by_id(resource, id), do: Ash.get!(resource, id, authorize?: false)

  def anchor(resource) do
    resource
    # authz-scope: corpus fixture — a deliberately org-less singleton anchor
    |> Ash.read_one(authorize?: false)
  end
end
