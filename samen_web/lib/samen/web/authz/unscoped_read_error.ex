defmodule Samen.Web.Authz.UnscopedReadError do
  @moduledoc """
  Raised by `Samen.Web.Authz.ReadScopeLint.assert_all_scoped!/1` when a direct
  `authorize?: false` read is neither pinned (org_id/id filter, by-id `Ash.get`, or a
  scalar aggregate) nor explicitly sanctioned as org-less (`# authz-scope:`). The loud
  gate failure T132 (defense-in-depth beyond T127) requires.
  """
  defexception [:message]
end
