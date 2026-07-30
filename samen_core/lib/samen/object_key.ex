defmodule Samen.ObjectKey do
  @moduledoc """
  The pure, host-agnostic "object-ref key" derivation (T122; ADR-009's
  derive-from-namespace rule, the SAME algorithm `Samen.Web.ObjectRef.Catalog.key_for/1`
  already documents) — a resource module's LAST TWO dotted segments, lowercased and
  underscored: `Driftwood.Support.Ticket -> "support.ticket"`, `Demo.SupportScope.Ticket
  -> "support_scope.ticket"`.

  ## Why this lives in samen_core, not samen_web

  `Samen.Web.ObjectRef.Catalog.key_for/1` is the ONLY existing implementation of this
  format, but it lives in samen_web (paired there with `resource_for/2`, the REVERSE
  direction — key -> module — which genuinely needs the host's `Samen.Web.Mount`
  namespace and therefore cannot move). The FORWARD direction (module -> key) needs no
  such context; it is a pure string transform. `Samen.Automation.Actions.AddTag`
  (T122, samen_core) needs to derive this SAME key when anchoring a `Tagging` row
  written by the automation engine, so a Tag attached via a workflow and a Tag attached
  via the samen_web UI (`Samen.Web.Tags.attach/5`) land on IDENTICAL `subject_key`
  values and are queryable back through the SAME read helpers. Since samen_web depends
  on samen_core and never the reverse (house CLAUDE.md), the shared algorithm has to
  live here; `Catalog.key_for/1` now delegates to this module instead of carrying its
  own copy, so there is exactly ONE implementation, not two that could drift.
  """

  @doc """
  The dotted, lowercased ref-key for a resource module — its last two module segments,
  underscored and joined by `.` (`Demo.Crm.Person -> "crm.person"`,
  `Demo.SupportScope.Ticket -> "support_scope.ticket"`).
  """
  @spec key_for(module()) :: String.t()
  def key_for(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> Enum.take(-2)
    |> Enum.map_join(".", &Macro.underscore/1)
  end
end
