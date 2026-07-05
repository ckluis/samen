defmodule SamenCore.TestRepo do
  @moduledoc """
  Ecto/AshPostgres repo used ONLY by samen_core's own test and dev fixtures.

  samen_core is a library; a host application supplies its own repo. This repo
  exists so the kernel's fixture resources (`test/support/*`) can be introspected
  by `mix ash.codegen` and exercised against a real Postgres in the test suite.
  """
  use AshPostgres.Repo, otp_app: :samen_core

  @impl true
  def installed_extensions do
    ["ash-functions"]
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
