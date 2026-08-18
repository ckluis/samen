defmodule Samen.Web.Docs do
  @moduledoc """
  The **Docs attach** write helper (F3; spec §F3 "attachable to any object via the
  existing object-ref system") — the org-scoped write boundary for anchoring a
  `Samen.Scopes.Docs` `Doc`/`Note` to ANY other catalogued host object.

  ## Why this lives in samen_web, not samen_core

  `samen_core`'s `Doc`/`Note` blueprint stores `subject_key`/`subject_id` as PLAIN
  scalars (mirrors `Samen.Scopes.Work.Task` exactly, ADR-041 §4.1) — samen_core cannot
  depend on `Samen.Web.ObjectRef` (samen_web depends on samen_core, never the reverse).
  Org-scope enforcement for the anchor therefore rides the SAME mechanism ADR-041 §6.1
  names for the canonical Task's future CRM client (`create_activity/3`): **resolve the
  subject ref through the org-scoped `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring.**

  `ObjectRef.resolve/3`'s private `load_scoped/3` loads the referenced row WITH THE
  VIEWER'S SCOPE — `Samen.Policy.OrgScope` narrows to `scope.actor.org_id`, so a
  cross-org id returns `[]` → `{:error, :not_found}` (a raise maps to `:forbidden`;
  never a leak, never an existence oracle). A cross-org attach is therefore **inert by
  construction**: `attach/5` refuses to persist the anchor unless the subject resolves
  on the caller's own org-scope. This is the INV-1 hard invariant this task ships:
  "a Note can't attach to / resolve another org's object."

  ## Generic over Doc AND Note (framework-first, one helper for both)

  `attach/5` takes the target resource module (`Docs.Doc` or `Docs.Note` on the host's
  namespace) and works identically for either — no resource-specific code.
  """

  alias Samen.Web.ObjectRef

  @doc """
  Create a `Doc`/`Note` row ANCHORED to `ref` (a `%Samen.Web.ObjectRef{}`), after
  resolving `ref` on the caller's org-scope.

    * `{:ok, record}`                    — the subject resolved (same-org, catalogued);
      the row is created with `subject_key`/`subject_id` set to the ref.
    * `{:error, {:subject_unresolved, reason}}` — the ref did not resolve on this
      scope (cross-org, unknown key, or a raise) — the row is NEVER created (no anchor,
      no orphaned write); `reason` is the underlying `ObjectRef.resolve/3` error
      (`:not_found | :unknown_key | :forbidden`).
    * `{:error, other}`                  — the underlying `Ash.create/2` failure
      (validation, policy, etc.) once the subject DID resolve.

  `mount` is ANY `%Samen.Web.Mount{}` sharing the target host's root namespace (the
  object-ref catalog derives the host root from `mount.namespace` by stripping its
  trailing scope segment — the SAME root resolves every key on that host regardless of
  which scope's mount constructed it, `Samen.Web.ObjectRef.Catalog` moduledoc).
  """
  @spec attach(Samen.Web.Mount.t(), Samen.Scope.t(), module(), map(), ObjectRef.t()) ::
          {:ok, struct()} | {:error, term()}
  def attach(mount, scope, resource, attrs, %ObjectRef{} = ref) do
    case ObjectRef.resolve(mount, scope, ref) do
      {:ok, _card} ->
        resource
        |> Ash.Changeset.for_create(
          :create,
          attrs
          |> Map.merge(%{subject_key: ref.key, subject_id: ref.id})
          |> Map.put_new(:org_id, actor_org_id(scope)),
          scope: scope
        )
        |> Ash.create()

      {:error, reason} ->
        {:error, {:subject_unresolved, reason}}
    end
  end

  defp actor_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp actor_org_id(_), do: nil

  @doc """
  `attach/5` from a raw `samen:<key>:<uuid>` ref STRING (the shape a composer/API
  caller carries) — `{:error, :unknown_key}` for a malformed string, never a raise.
  """
  @spec attach_ref(Samen.Web.Mount.t(), Samen.Scope.t(), module(), map(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def attach_ref(mount, scope, resource, attrs, ref_str) when is_binary(ref_str) do
    case ObjectRef.from_string(ref_str) do
      {:ok, ref} -> attach(mount, scope, resource, attrs, ref)
      :error -> {:error, {:subject_unresolved, :unknown_key}}
    end
  end
end
