defmodule PawChartWeb.Layouts do
  @moduledoc """
  The PawChart root layout — the shared Samen shell (WS-D D1.4, ADR-022).
  The hand-authored HTML moved into `Samen.Web.Layouts`; this module inherits
  it, keeping PawChart's original title.
  """
  use Samen.Web.Layouts, title: "PawChart — vet clinic SaaS on Samen"
end
