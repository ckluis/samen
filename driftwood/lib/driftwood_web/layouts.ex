defmodule DriftwoodWeb.Layouts do
  @moduledoc """
  The Driftwood root layout — the shared Samen shell (WS-D D1.4, ADR-022).
  The hand-authored HTML (T5.3) moved into `Samen.Web.Layouts`; this module
  inherits it. Title defaults to "Driftwood" (derived from the module name).
  """
  use Samen.Web.Layouts
end
