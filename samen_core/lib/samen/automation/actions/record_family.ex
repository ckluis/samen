defmodule Samen.Automation.Actions.MutateRecord do
  @moduledoc """
  ADR-039 §5.2 #3 — `mutate_record`: the MERGED create/update action (spec §E2's
  "create/update a record" is one item; `mode` picks the branch — this is the
  merge ADR-039 makes to keep the action library at exactly 8 kinds). Both
  branches execute as the run OWNER (`ctx.actor`) through a GOVERNED Ash action
  — no system-actor bypass (ADR-039 §4.5; T40 c3): a policy that refuses the
  owner's write surfaces as `{:error, :unauthorized}`.

  ## `mode: "create"`

  Targets `config["resource_key"]` (may name a DIFFERENT resource than the
  trigger's own — e.g. a ticket-created rule that creates a follow-up task).
  `attrs` are literal values or `{{subject.<attr>}}` interpolations
  (eligible-only by construction, `Samen.Automation.Actions.Support.interpolate/2`).
  `undo/3` destroys the created record — a MEANINGFUL reversal (ADR-037 §5.7).

  ## `mode: "update"`

  Targets the SUBJECT (`ctx.resource_key`/`ctx.record_id`). `undo/3` is a
  DOCUMENTED no-op: reversing an update requires snapshotting the PRIOR
  attribute values, which may be PII — INV-1 outranks undo fidelity (ADR-039
  §5.2 #3 / §13 "rejected alternatives: snapshot-based undo for update actions").
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context

  @impl true
  def kind, do: :mutate_record

  @impl true
  def validate(%{"mode" => mode} = config, _resource_key) when mode in ["create", "update"] do
    attrs = config["attrs"] || %{}

    cond do
      mode == "create" and (not is_binary(config["resource_key"]) or config["resource_key"] == "") ->
        {:error, :missing_resource_key}

      not is_map(attrs) ->
        {:error, :invalid_attrs}

      true ->
        {:ok, %{"mode" => mode, "resource_key" => config["resource_key"], "attrs" => attrs}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(%{"mode" => "create"} = config, %Context{} = ctx) do
    with {:ok, resource} <- Support.resolve_resource(config["resource_key"]) do
      # org_id is ALWAYS the run's own org — never config-authored, never
      # subject-interpolated (a workflow cannot mint a record in another org).
      attrs =
        config["attrs"]
        |> to_map()
        |> Support.interpolate(ctx)
        |> atomize()
        |> Map.put(:org_id, ctx.org_id)

      case Support.governed_create(resource, attrs, ctx) do
        {:ok, record} ->
          {:ok,
           %{
             kind: :mutate_record,
             mode: :create,
             record_id: to_string(record.id),
             resource_key: config["resource_key"]
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :unknown_resource}
    end
  end

  def run(%{"mode" => "update"} = config, %Context{} = ctx) do
    with {:ok, record} <- Support.fetch_subject(ctx) do
      attrs = config["attrs"] |> to_map() |> Support.interpolate(ctx) |> atomize()

      case Support.governed_update(record, attrs, ctx) do
        {:ok, updated} ->
          {:ok, %{kind: :mutate_record, mode: :update, record_id: to_string(updated.id)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(_config, _ctx), do: {:error, :invalid_config}

  @impl true
  def undo(_config, %{mode: :create, record_id: record_id, resource_key: resource_key}, %Context{
        actor: actor
      })
      when is_binary(record_id) and is_binary(resource_key) do
    with {:ok, resource} <- Support.resolve_resource(resource_key),
         {:ok, record} <- Ash.get(resource, record_id, actor: actor) do
      record |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor) |> Ash.destroy()
      :ok
    else
      _ -> :ok
    end
  end

  def undo(_config, _meta, _ctx), do: :ok

  defp to_map(m) when is_map(m), do: m
  defp to_map(_), do: %{}

  defp atomize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {Support.safe_atom(to_string(k)) || k, v} end)
end

defmodule Samen.Automation.Actions.AssignOwner do
  @moduledoc """
  ADR-039 §5.2 #4 — `assign_owner`: a governed update setting a bounded id
  attribute (default `owner_id`) on the SUBJECT record. `user_id` is either a
  literal id or the sentinel `"workflow_owner"` (resolves to the run's own
  owner-actor id — the same "owner" selector convention `notify`/`send_email`
  use). Like `mutate_record`'s update mode, `undo/3` is a documented no-op
  (INV-1 over undo fidelity — reversing needs the prior value, which the engine
  never captures).
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context

  @impl true
  def kind, do: :assign_owner

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    attribute = config["attribute"] || "owner_id"
    user_id = config["user_id"]

    cond do
      not is_binary(attribute) or attribute == "" ->
        {:error, :invalid_attribute}

      not is_binary(user_id) or user_id == "" ->
        {:error, :invalid_user_id}

      true ->
        {:ok, %{"attribute" => attribute, "user_id" => user_id}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    attribute = config["attribute"] || "owner_id"
    value = resolve_user(config["user_id"], ctx)

    case Support.safe_atom(attribute) do
      nil ->
        {:error, :invalid_attribute}

      attr ->
        with {:ok, record} <- Support.fetch_subject(ctx),
             {:ok, updated} <- Support.governed_update(record, %{attr => value}, ctx) do
          {:ok, %{kind: :assign_owner, record_id: to_string(updated.id), attribute: attribute}}
        end
    end
  end

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

  defp resolve_user("workflow_owner", ctx), do: Support.actor_id(ctx.actor)
  defp resolve_user(user_id, _ctx) when is_binary(user_id), do: user_id
  defp resolve_user(_, ctx), do: Support.actor_id(ctx.actor)
end

defmodule Samen.Automation.Actions.AddTag do
  @moduledoc """
  ADR-039 §5.2 #5 / §5.4 — `add_tag`: attaches a bounded tag string to the
  SUBJECT record. `add_tag`'s external config contract (`%{"tag" => tag_string}`)
  is F4-stable and UNCHANGED by T122 (ADR-039 §5.2 #5) — only the resolution of
  "where a tag lives" branches on the subject's resource.

  ## T122 — rewired onto the generic F4 Tag/Tagging mechanism (shipped)

  Two branches, picked per subject resource:

    1. **`:tags_scope_resources`-declared resource** (config seam, host-owned,
       mirrors `:support_sla_breach_ticket_resource`'s shape —
       `config :samen_core, :tags_scope_resources, %{MyHost.SupportScope.Ticket
       => MyHost.Tags.Tagging}`): the tag is resolved/find-or-created as a real
       `Samen.Scopes.Tags` `Tag` row in the SUBJECT'S OWN org (`ctx.org_id` —
       never subject-interpolated, mirroring `MutateRecord`'s create-mode
       `org_id` rule) and attached via a governed `Tagging` create, anchored at
       `subject_key = Samen.ObjectKey.key_for(subject_resource)` /
       `subject_id = record.id` — the SAME key format
       `Samen.Web.ObjectRef.Catalog.key_for/1` derives (they now share ONE
       implementation, `Samen.ObjectKey.key_for/1`), so a Tag attached by a
       workflow and a Tag attached via the samen_web UI
       (`Samen.Web.Tags.attach/5`) are queryable back through the SAME read
       helpers (`Samen.Web.Tags.names_for/4` et al). `Support.Ticket` is wired
       into this branch on every host that declares it (e.g. demo's
       `Demo.SupportScope.Ticket => Demo.Tags.Tagging`) — `add_tag` against a
       Ticket now creates a real, queryable Tagging instead of the old
       `{:error, :no_tag_surface}`.
    2. **Everything else (the F4/T40 array-attribute seam, unchanged)**: the
       ORIGINAL designed seam — a resource declaring a public `tags` array
       attribute (the `SamenCore.Support.AutomationFixture.Target` fixture,
       deliberately decoupled from Support.Ticket) — a resource with neither a
       `:tags_scope_resources` entry NOR a `tags` array attribute returns the
       honest `{:error, :no_tag_surface}`, exactly as before — never a fake
       success.

  ## Org-scope (no hand-rolled second check)

  The Tag-scope branch rides TWO already-governed, already-tested mechanisms —
  no new scope-check code:

    * the SUBJECT is read via `Support.fetch_subject/1`, which authorizes as
      `ctx.actor` against the subject resource's OWN `Samen.Policy.OrgScope`
      read policy — a cross-org `record_id` never resolves (an honest
      `{:error, :not_found}`/`{:error, :unauthorized}`, never an orphaned
      write, exactly mirroring the guarantee `Samen.Web.ObjectRef.resolve/3`'s
      `load_scoped/3` gives `Samen.Web.Tags.attach/5`);
    * the Tag/Tagging WRITES are governed `Ash.create`s (`Support.governed_create/3`,
      `actor: ctx.actor`) against the `Tag`/`Tagging` resources' OWN
      `Samen.Policy.OrgScope` + `RoleAtLeast(member)` create policies (the SAME
      policies `attach/5`'s writes are gated by) — `org_id` is always
      `ctx.org_id` (the run's own org), never subject-derived, so a workflow
      cannot mint a Tag/Tagging in another org even if it wanted to.

  ## INV-1

  `Tagging` is structurally closed to `id/org_id/inserted_at/updated_at/tag_id/
  subject_key/subject_id` (`Samen.Scopes.Tags.Blueprint` moduledoc) — no
  attribute exists that could carry a copy of the subject's vault fields.
  `add_tag`'s own return shape stays `%{kind: :add_tag, record_id: _, tag: _}` —
  bounded ids/enums only, exactly as before.

  ## Idempotency

  Both the Tag find-or-create and the Tagging create are find-THEN-create (with
  a re-find fallback on a write conflict) — repeating `add_tag` with the SAME
  tag string against the SAME subject reuses the existing Tag row (org+name)
  and does not create a duplicate Tagging (mirrors the Tag's own live
  `(org_id, name)` uniqueness and the Tagging's own `(tag_id, subject_key,
  subject_id)` uniqueness — the same invariants T46's migration idempotency
  proof already established).
  """

  @behaviour Samen.Automation.Action

  require Ash.Query

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context

  @impl true
  def kind, do: :add_tag

  @impl true
  def validate(%{"tag" => tag}, _resource_key) when is_binary(tag) and tag != "" do
    {:ok, %{"tag" => tag}}
  end

  def validate(_config, _resource_key), do: {:error, :invalid_tag}

  @impl true
  def run(%{"tag" => tag}, %Context{} = ctx) when is_binary(tag) and tag != "" do
    with {:ok, record} <- Support.fetch_subject(ctx) do
      case tags_scope_tagging_resource(record.__struct__) do
        {:ok, tagging_resource} -> run_tags_scope(record, tagging_resource, tag, ctx)
        :error -> run_array_attribute(record, tag, ctx)
      end
    end
  end

  def run(_config, _ctx), do: {:error, :invalid_config}

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

  # -- branch 1 (T122): the generic F4 Tag/Tagging mechanism -------------------

  # The `:tags_scope_resources` config seam — per-host declaration of which
  # subject resources `add_tag` targets via the generic mechanism, mapped to
  # the host's `Tags.Tagging` module (mirrors `:support_sla_breach_ticket_resource`).
  # No entry ⇒ falls through to the array-attribute branch (`:error`).
  defp tags_scope_tagging_resource(resource) do
    :samen_core
    |> Application.get_env(:tags_scope_resources, %{})
    |> Map.get(resource)
    |> case do
      nil -> :error
      tagging_resource -> {:ok, tagging_resource}
    end
  end

  defp run_tags_scope(record, tagging_resource, tag, ctx) do
    with {:ok, tag_mod} <- tag_module_for(tagging_resource),
         {:ok, tag_row} <- find_or_create_tag(tag_mod, tag, ctx) do
      subject_key = Samen.ObjectKey.key_for(record.__struct__)
      subject_id = to_string(record.id)

      case find_or_create_tagging(tagging_resource, tag_row.id, subject_key, subject_id, ctx) do
        {:ok, _tagging} -> {:ok, %{kind: :add_tag, record_id: subject_id, tag: tag}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The Tag module rides the Tagging resource's OWN `belongs_to :tag` relationship
  # (materialized together by the same `Samen.Scopes.Tags` blueprint call) — never a
  # second config entry, never guessed.
  defp tag_module_for(tagging_resource) do
    case Ash.Resource.Info.relationship(tagging_resource, :tag) do
      %{type: :belongs_to, destination: tag_mod} -> {:ok, tag_mod}
      _ -> {:error, :invalid_tag_scope_config}
    end
  end

  defp find_or_create_tag(tag_mod, name, ctx) do
    case find_tag_row(tag_mod, name, ctx) do
      {:ok, tag} ->
        {:ok, tag}

      :error ->
        case Support.governed_create(tag_mod, %{name: name, org_id: ctx.org_id}, ctx) do
          {:ok, tag} -> {:ok, tag}
          # A concurrent writer may have created the same (org, name) Tag
          # between the find and the create (unique-index conflict) — re-find
          # once before surfacing a genuine failure (idempotency, not a raise).
          {:error, _reason} -> retry_or_error(fn -> find_tag_row(tag_mod, name, ctx) end, :tag_create_failed)
        end
    end
  end

  defp find_tag_row(tag_mod, name, %Context{actor: actor}) do
    tag_mod
    |> Ash.Query.filter(name == ^name)
    |> Ash.read(actor: actor)
    |> first_row()
  end

  defp find_or_create_tagging(tagging_resource, tag_id, subject_key, subject_id, ctx) do
    case find_tagging_row(tagging_resource, tag_id, subject_key, subject_id, ctx) do
      {:ok, tagging} ->
        {:ok, tagging}

      :error ->
        attrs = %{tag_id: tag_id, subject_key: subject_key, subject_id: subject_id, org_id: ctx.org_id}

        case Support.governed_create(tagging_resource, attrs, ctx) do
          {:ok, tagging} ->
            {:ok, tagging}

          {:error, _reason} ->
            retry_or_error(
              fn -> find_tagging_row(tagging_resource, tag_id, subject_key, subject_id, ctx) end,
              :tagging_create_failed
            )
        end
    end
  end

  defp find_tagging_row(tagging_resource, tag_id, subject_key, subject_id, %Context{actor: actor}) do
    tagging_resource
    |> Ash.Query.filter(tag_id == ^tag_id and subject_key == ^subject_key and subject_id == ^subject_id)
    |> Ash.read(actor: actor)
    |> first_row()
  end

  defp retry_or_error(retry_fun, error_kind) do
    case retry_fun.() do
      {:ok, row} -> {:ok, row}
      :error -> {:error, error_kind}
    end
  end

  # `:error` for zero rows OR a read failure — both fall through to "does not
  # exist yet" for the find-or-create callers above. Governed (`actor: ctx.actor`
  # — the SAME already-tested actor-passing convention
  # `Support.governed_update/create` use; no new authorization path).
  defp first_row({:ok, [row | _]}), do: {:ok, row}
  defp first_row({:ok, []}), do: :error
  defp first_row({:error, _reason}), do: :error

  # -- branch 2 (unchanged, F4/T40): the array-attribute seam ------------------

  defp run_array_attribute(record, tag, ctx) do
    case tag_surface(record) do
      {:ok, current} ->
        new_tags = Enum.uniq(current ++ [tag])

        case Support.governed_update(record, %{tags: new_tags}, ctx) do
          {:ok, updated} -> {:ok, %{kind: :add_tag, record_id: to_string(updated.id), tag: tag}}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :no_tag_surface}
    end
  end

  # A "tag surface" is a resource declaring a public `tags` attribute typed as
  # an array of strings (the Ticket precedent, ADR-039 §5.4). A resource with no
  # such attribute (or a differently-typed one) is refused, never faked.
  defp tag_surface(%resource{} = record) do
    case Ash.Resource.Info.attribute(resource, :tags) do
      %{type: {:array, item_type}} ->
        if string_type?(item_type), do: {:ok, Map.get(record, :tags) || []}, else: :error

      _ ->
        :error
    end
  end

  defp string_type?(:string), do: true
  defp string_type?(Ash.Type.String), do: true
  defp string_type?(_), do: false
end
