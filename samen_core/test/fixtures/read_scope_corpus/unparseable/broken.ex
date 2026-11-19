defmodule ReadScopeCorpus.Broken do
  def oops(resource) do
    Ash.read!(resource, authorize?: false
  end
