defmodule ReadScopeCorpus.Leak do
  def every_orgs_rows(resource) do
    Ash.read!(resource, authorize?: false)
  end
end
