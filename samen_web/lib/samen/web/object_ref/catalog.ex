defmodule Samen.Web.ObjectRef.Catalog do
  @moduledoc """
  Ref-key ↔ resource-module translation for object unfurl (ADR-012 §4.1) — the
  derive-from-namespace rule (ADR-009), applied to catalog keys.

  A ref key is the resource-qualified catalog key: `<scope>.<resource>` (`crm.person`,
  `support.ticket`, `billing.invoice`, `freight.driver`) — the LAST TWO dotted, lowercased
  segments of the resource module. This is stable and host-agnostic: the SAME key `crm.person`
  resolves to `Driftwood.Crm.Person` in driftwood and `PawChart.Crm.Person` in pawchart, so a
  ref copied on one host is meaningful there without ever embedding a host module name in text.

  ## Why the mount is required to resolve a key

  The key is host-AGNOSTIC by design — resolving it needs the mount's HOST ROOT (the namespace
  minus its scope segment). `Samen.WebTest.Crm` → root `Samen.WebTest`; a key `crm.person` then
  reconstructs `Samen.WebTest.Crm.Person`. The mount's `namespace` carries the concrete host, so
  the key never has to. This mirrors `Samen.Web.Mount.resource/2` (ADR-004's
  `Module.concat(namespace, Name)` convention) generalized across scopes.

  ## Fail-safe

  A key that maps to no compiled/loaded resource module returns `{:error, :unknown_key}` — a
  pasted `samen:bogus.thing:…` becomes an inert "unknown object" chip, never a raise or a leak.
  Resolution is checked against `Ash.Resource.Info` so a well-formed-but-nonexistent key cannot
  masquerade as a resource.
  """

  alias Samen.Web.Mount

  @doc """
  The catalog key for a resource MODULE — its last two module segments, lowercased and dotted.
  `Driftwood.Crm.Person -> "crm.person"`, `Driftwood.Support.Ticket -> "support.ticket"`.

  Delegates to `Samen.ObjectKey.key_for/1` (T122) — the pure derivation now lives in
  samen_core so `Samen.Automation.Actions.AddTag` can derive the SAME key without
  samen_core depending on samen_web. This module stays the source of the REVERSE
  direction (`resource_for/2`, key -> module), which genuinely needs the host's
  `Samen.Web.Mount` namespace and cannot move.
  """
  @spec key_for(module()) :: String.t()
  def key_for(resource) when is_atom(resource), do: Samen.ObjectKey.key_for(resource)

  @doc """
  Resolve a ref key to a resource module FOR THIS MOUNT (derive-from-namespace).

    * `{:ok, module}`          — the key maps to a compiled resource for this host.
    * `{:error, :unknown_key}` — malformed key, or no such resource in this host.
  """
  @spec resource_for(Mount.t(), String.t()) :: {:ok, module()} | {:error, :unknown_key}
  def resource_for(%Mount{namespace: ns}, key) when is_binary(key) do
    with {:ok, {scope_seg, resource_seg}} <- split_key(key),
         {:ok, root} <- host_root(ns) do
      module = Module.concat([root, camelize(scope_seg), camelize(resource_seg)])

      if catalogued_resource?(module) do
        {:ok, module}
      else
        {:error, :unknown_key}
      end
    end
  end

  # -- private -----------------------------------------------------------------

  # A key is exactly `<scope>.<resource>`. More/fewer segments is malformed.
  defp split_key(key) do
    case String.split(key, ".") do
      [scope, resource] when scope != "" and resource != "" -> {:ok, {scope, resource}}
      _ -> {:error, :unknown_key}
    end
  end

  # The host root is the namespace minus its trailing scope segment:
  # `Samen.WebTest.Crm` -> `Samen.WebTest`. A one-segment namespace has no root to strip.
  defp host_root(namespace) do
    case Module.split(namespace) do
      [_only] -> {:error, :unknown_key}
      segments -> {:ok, Module.concat(Enum.drop(segments, -1))}
    end
  end

  # Camelize a lowercased-underscored segment back to a module segment
  # (`freight` -> `Freight`, `desk_note` -> `DeskNote`).
  defp camelize(seg), do: Macro.camelize(seg)

  # Is this an actual catalogued Ash resource? A well-formed key that names no compiled
  # resource must fail (no existence oracle, no raise). `Ash.Resource.Info.resource?/1`
  # returns false for a non-resource / non-loaded module without raising.
  defp catalogued_resource?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :spark_is, 0) and
      Ash.Resource.Info.resource?(module)
  rescue
    _ -> false
  end
end
