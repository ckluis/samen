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
  ADR-039 §5.2 #5 / §5.4 — `add_tag`: appends a bounded tag string to the
  SUBJECT's `tags` array attribute where the catalog has one. Targets a
  DESIGNED SEAM, not a stub: a resource with no `tags` attribute returns the
  honest `{:error, :no_tag_surface}` — never a fake success.

  ## F4/T46 status (a scope note, not a stub)

  F4 shipped the generic `Samen.Scopes.Tags` `Tag`/`Tagging` resource and
  migrated `Support.Ticket`'s bespoke `tags` array OFF this seam onto the
  generic mechanism (`MigrateTicketTagsToTagScope`) — so `add_tag` against a
  Ticket now honestly returns `{:error, :no_tag_surface}` (Ticket no longer
  declares a `tags` attribute at all). Re-pointing THIS action's write path at
  a Tagging create (so `add_tag` keeps working against Ticket, and gains every
  OTHER Tag-scope-eligible resource) is deliberately left as documented
  follow-up work, decomposed out of T46 per the standing "decompose
  cross-cutting changes" convention — it requires a per-host
  `:tags_scope_resources` config seam (mirroring
  `:support_sla_breach_ticket_resource`) threaded through the automation
  engine, which no host currently configures. `add_tag`'s config contract
  (`tag` string) is unaffected and stays F4-stable by design; only the
  resolution of "where a tag lives" changes when that follow-up lands. The
  `SamenCore.Support.AutomationFixture.Target` fixture (a standalone `tags`
  array surface, deliberately decoupled from Support.Ticket) continues to
  exercise the CURRENT array-attribute mechanism unaffected by T46.
  """

  @behaviour Samen.Automation.Action

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
  end

  def run(_config, _ctx), do: {:error, :invalid_config}

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

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
