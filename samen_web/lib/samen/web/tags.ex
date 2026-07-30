defmodule Samen.Web.Tags do
  @moduledoc """
  The **Tags attach + read** write/read helper (F4; spec §F4) — the org-scoped write
  boundary for anchoring a `Samen.Scopes.Tags` `Tagging` to ANY other catalogued host
  object, plus a batched read helper for "what tags does this object have" (the Ticket
  migration's read-equivalence surface).

  ## Why this lives in samen_web, not samen_core (mirrors `Samen.Web.Docs`)

  `samen_core`'s `Tagging` blueprint stores `subject_key`/`subject_id` as PLAIN scalars
  (mirrors `Samen.Scopes.Work.Task` / `Samen.Scopes.Docs.{Doc,Note}` exactly, ADR-041
  §4.1) — samen_core cannot depend on `Samen.Web.ObjectRef` (samen_web depends on
  samen_core, never the reverse). Org-scope enforcement for the anchor therefore rides
  the SAME mechanism ADR-041 §6.1 names: **resolve the subject ref through the
  org-scoped `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring.**

  `ObjectRef.resolve/3`'s private `load_scoped/3` loads the referenced row WITH THE
  VIEWER'S SCOPE — `Samen.Policy.OrgScope` narrows to `scope.actor.org_id`, so a
  cross-org id returns `[]` → `{:error, :not_found}` (never a leak, never an existence
  oracle). A cross-org attach is therefore **inert by construction**: `attach/5`
  refuses to persist the Tagging unless the subject resolves on the caller's own
  org-scope. This is the F4 hard invariant: "a Tag can only attach to same-org
  objects."

  ## Generic over any resource kind (framework-first, one helper for every subject)

  `attach/5` takes ANY `ref` (a `%Samen.Web.ObjectRef{}`) — a support ticket, a CRM
  person, a Work task, … — no resource-specific code, exactly like `Samen.Web.Docs`.

  ## Read side — `names_by_subject/4` / `names_for/4`

  Batched tag-NAME lookup for many subjects of the SAME resource kind, keyed by
  subject_id. Derives the host's `Tagging` module via the object-ref catalog
  (`ObjectRef.Catalog.resource_for(mount, "tags.tagging")`) — if the host has not
  mounted the Tags scope, every lookup fails safe to an empty result (never raises,
  never a fake `[]` masquerading as "no tags" vs. "scope not mounted" ambiguity is a
  concern here — both degrade to empty, which is the correct fail-safe UI posture: an
  absent Tags scope simply shows no tags, exactly like a scope with none attached).
  """

  alias Samen.Web.ObjectRef
  alias Samen.Web.ObjectRef.Catalog

  require Ash.Query

  @doc """
  Attach `tag_id` to `ref` (a `%Samen.Web.ObjectRef{}`), after resolving `ref` on the
  caller's org-scope. `tagging_resource` is the host's `Tags.Tagging` module.

    * `{:ok, tagging}`                         — the subject resolved (same-org,
      catalogued); the Tagging row is created anchored to `ref`.
    * `{:error, {:subject_unresolved, reason}}` — the ref did not resolve on this
      scope (cross-org, unknown key, or a raise) — the row is NEVER created (no
      orphaned write); `reason` mirrors `ObjectRef.resolve/3`
      (`:not_found | :unknown_key | :forbidden`).
    * `{:error, other}`                        — the underlying `Ash.create/2`
      failure (validation, policy, a duplicate attach, etc.) once the subject DID
      resolve.
  """
  @spec attach(Samen.Web.Mount.t(), Samen.Scope.t(), module(), String.t(), ObjectRef.t()) ::
          {:ok, struct()} | {:error, term()}
  def attach(mount, scope, tagging_resource, tag_id, %ObjectRef{} = ref) do
    case ObjectRef.resolve(mount, scope, ref) do
      {:ok, _card} ->
        tagging_resource
        |> Ash.Changeset.for_create(
          :create,
          %{tag_id: tag_id, subject_key: ref.key, subject_id: ref.id}
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
  `attach/5` from a raw `samen:<key>:<uuid>` ref STRING — `{:error, :unknown_key}` for
  a malformed string, never a raise. Mirrors `Samen.Web.Docs.attach_ref/5`.
  """
  @spec attach_ref(Samen.Web.Mount.t(), Samen.Scope.t(), module(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def attach_ref(mount, scope, tagging_resource, tag_id, ref_str) when is_binary(ref_str) do
    case ObjectRef.from_string(ref_str) do
      {:ok, ref} -> attach(mount, scope, tagging_resource, tag_id, ref)
      :error -> {:error, {:subject_unresolved, :unknown_key}}
    end
  end

  @doc """
  Detach (untag) `tag_id` from `ref` — destroys the matching `Tagging` row for the
  caller's org-scope. `:ok` (idempotent — no matching row is also `:ok`, never an
  error) or `{:error, reason}` on a genuine write failure.
  """
  @spec detach(Samen.Web.Mount.t(), Samen.Scope.t(), module(), String.t(), ObjectRef.t()) ::
          :ok | {:error, term()}
  def detach(mount, scope, tagging_resource, tag_id, %ObjectRef{key: key, id: id}) do
    _ = mount

    tagging_resource
    |> Ash.Query.filter(tag_id == ^tag_id and subject_key == ^key and subject_id == ^id)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [row | _]} -> row |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope) |> Ash.destroy()
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Batched tag-NAME lookup for MANY subjects of the SAME resource kind
  (`%{subject_id => [tag_name, ...]}`, each list sorted, deduplicated). `subject_key`
  should be `ObjectRef.Catalog.key_for(subject_resource)` so it matches whatever
  `attach/5` (or a migration) wrote. Fails safe to `%{}` for every input if the host
  has not mounted the Tags scope, or on any read error — never raises.
  """
  @spec names_by_subject(Samen.Web.Mount.t(), Samen.Scope.t(), String.t(), [String.t()]) ::
          %{optional(String.t()) => [String.t()]}
  def names_by_subject(mount, scope, subject_key, subject_ids) when is_list(subject_ids) do
    case Catalog.resource_for(mount, "tags.tagging") do
      {:ok, tagging_mod} ->
        tagging_mod
        |> Ash.Query.filter(subject_key == ^subject_key and subject_id in ^subject_ids)
        |> Ash.Query.load(:tag)
        |> Ash.read(scope: scope)
        |> case do
          {:ok, taggings} -> group_names(taggings)
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  @doc """
  Batched tag-NAME lookup for EVERY subject of the SAME resource kind (no
  pre-known id list needed) — for a bounded LIST view join, mirroring the
  `agent_by_ticket`-style "read everything up to the lookup limit, bucket by
  key" batching already used elsewhere in this framework (`Samen.Web.
  Operator.Reads.agent_by_ticket/2`). Same fail-safe posture as
  `names_by_subject/4`.
  """
  @spec names_by_subject_key(Samen.Web.Mount.t(), Samen.Scope.t(), String.t(), pos_integer()) ::
          %{optional(String.t()) => [String.t()]}
  def names_by_subject_key(mount, scope, subject_key, limit) do
    case Catalog.resource_for(mount, "tags.tagging") do
      {:ok, tagging_mod} ->
        tagging_mod
        |> Ash.Query.filter(subject_key == ^subject_key)
        |> Ash.Query.limit(limit)
        |> Ash.Query.load(:tag)
        |> Ash.read(scope: scope)
        |> case do
          {:ok, taggings} -> group_names(taggings)
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  @doc "Tag names for ONE subject — `names_by_subject/4` for a single id."
  @spec names_for(Samen.Web.Mount.t(), Samen.Scope.t(), String.t(), String.t()) :: [String.t()]
  def names_for(mount, scope, subject_key, subject_id) do
    names_by_subject(mount, scope, subject_key, [subject_id])
    |> Map.get(subject_id, [])
  end

  defp group_names(taggings) do
    taggings
    |> Enum.group_by(& &1.subject_id, fn t -> t.tag && t.tag.name end)
    |> Map.new(fn {k, v} -> {k, v |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()} end)
  end
end
