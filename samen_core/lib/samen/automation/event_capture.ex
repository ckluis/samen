defmodule Samen.Automation.EventCapture do
  @moduledoc """
  Transactional resource-event capture (ADR-039 §4.2) — an Ash **after-action** change
  that runs INSIDE the write transaction and `Oban.insert`s one `DispatchWorker` job in
  the same transaction. Transactional capture: the dispatch job exists iff the write
  committed, and it commits atomically with it — no after-commit gap can lose the event
  and no phantom job survives a rolled-back write.

  Attach it to a trigger-source resource's create/update/destroy actions:

      changes do
        change(Samen.Automation.EventCapture)
      end

  (Left to the adopting resource / the base macro — T39 attaches it to the automation
  test fixture's subject to prove the mechanism; broad adoption is the substrate-first
  follow-up, INV-5.)

  ## The envelope is non-PII by construction (ADR-039 §4.2 / §10.2)

      %{org_id, resource_key, event, record_id, changed: [attribute_NAMES],
        event_id, subject_ref, trigger_kind, depth, chain: [workflow_ids]}

  Attribute *names* are catalog metadata, not data. No attribute VALUE is ever
  serialized into `oban_jobs.args` (the ADR-037 §5.9 sink rule) — `changed` is a list
  of names, and there is no values map anywhere in the envelope.

  ## Write-amplification guard

  Capture consults the host `Workflow` module for an active workflow matching
  `org+resource_key+event` and inserts NOTHING when none matches. The match query is
  authoritative-but-defensive: a query error degrades to "skip" (a broken scan must
  never roll back an unrelated tenant write — correctness of *capture* rides on the
  in-txn insert, cost rides on the match). When the engine is UNWIRED
  (`workflow_module == nil`) capture is fully inert.

  ## Loop provenance (ADR-039 §4.7)

  A write performed BY a run carries `changeset.context[:automation] = %{depth, chain}`;
  the captured event inherits `depth + 1` and `chain ++ [workflow_id]`, so the cycle
  and depth guards downstream can refuse self-triggering cascades.
  """
  use Ash.Resource.Change

  require Logger

  alias Samen.Automation
  alias Samen.Automation.DispatchWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      capture(changeset, result)
      {:ok, result}
    end)
  end

  # after_action returns {:ok, result} regardless — capture is best-effort-within-txn:
  # it never fails the tenant write, but its insert (when a workflow matches) commits
  # atomically inside the same transaction.
  defp capture(changeset, result) do
    workflow_mod = Automation.workflow_module()

    if is_nil(workflow_mod) do
      :ok
    else
      resource_key = inspect(changeset.resource)
      event = event_of(changeset.action.type)
      record_id = get(result, :id)
      org_id = resolve_org_id(changeset, result, record_id)

      if is_nil(org_id) or is_nil(record_id) or is_nil(event) do
        :ok
      else
        do_capture(workflow_mod, changeset, resource_key, event, org_id, record_id)
      end
    end
  rescue
    e ->
      Logger.warning("[Automation.EventCapture] capture raised: #{Exception.message(e)}")
      :ok
  end

  defp do_capture(workflow_mod, changeset, resource_key, event, org_id, record_id) do
    if active_match?(workflow_mod, org_id, resource_key, event) do
      {depth, chain} = provenance(changeset)

      envelope =
        envelope(%{
          org_id: org_id,
          resource_key: resource_key,
          event: event,
          record_id: record_id,
          changed: changed_names(changeset),
          subject_ref: subject_ref(resource_key, record_id),
          trigger_kind: :resource_event,
          depth: depth,
          chain: chain
        })

      case Oban.insert(DispatchWorker.new(envelope)) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          # In-txn insert failed; log but do not roll back the tenant write. The
          # transactional guarantee (no after-commit gap) is preserved by being in
          # the txn on success; on failure we protect the business write.
          Logger.warning("[Automation.EventCapture] dispatch enqueue failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Normalize a field map into the string-keyed, values-free envelope (Oban args must be
  json-encodable string-keyed maps). Public so tests can assert the shape directly.
  """
  @spec envelope(map()) :: map()
  def envelope(fields) do
    %{
      "org_id" => to_s(fields[:org_id] || fields["org_id"]),
      "resource_key" => to_s(fields[:resource_key] || fields["resource_key"]),
      "event" => to_s(fields[:event] || fields["event"]),
      "record_id" => to_s(fields[:record_id] || fields["record_id"]),
      "subject_ref" => to_s(fields[:subject_ref] || fields["subject_ref"]),
      "trigger_kind" => to_s(fields[:trigger_kind] || fields["trigger_kind"] || "resource_event"),
      "changed" => Enum.map(List.wrap(fields[:changed] || fields["changed"] || []), &to_string/1),
      "event_id" => to_s(fields[:event_id] || fields["event_id"] || Ecto.UUID.generate()),
      "depth" => fields[:depth] || fields["depth"] || 0,
      "chain" => Enum.map(List.wrap(fields[:chain] || fields["chain"] || []), &to_string/1)
    }
  end

  # ---------------------------------------------------------------------------

  # Authoritative-but-defensive active-workflow existence check.
  defp active_match?(workflow_mod, org_id, resource_key, event) do
    import Ash.Query

    workflow_mod
    |> filter(org_id == ^org_id)
    |> filter(resource_key == ^resource_key)
    |> filter(trigger_kind == :resource_event)
    |> filter(event == ^event)
    |> filter(status == :active)
    |> filter(is_nil(disabled_by_operator_at))
    |> limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_ | _] -> true
    end
  rescue
    _ -> false
  end

  defp event_of(:create), do: :created
  defp event_of(:update), do: :updated
  defp event_of(:destroy), do: :destroyed
  defp event_of(_), do: nil

  # The set of attribute LOGICAL names actually changing in this write.
  defp changed_names(changeset) do
    changeset.attributes
    |> Map.keys()
    |> Enum.filter(&Ash.Changeset.changing_attribute?(changeset, &1))
  end

  defp provenance(changeset) do
    case changeset.context do
      %{automation: %{depth: depth, chain: chain}} -> {depth, chain}
      %{automation: %{"depth" => depth, "chain" => chain}} -> {depth, chain}
      _ -> {0, []}
    end
  end

  # Object ref: "samen:<lower.resource>:<id>". We derive a coarse key from the module
  # tail (bounded reference, never subject data).
  defp subject_ref(resource_key, record_id) do
    tail = resource_key |> String.split(".") |> List.last() |> String.downcase()
    "samen:#{tail}:#{record_id}"
  end

  # org_id is a universal column not selected by default; resolve it reliably from the
  # changeset (create), the loaded data (update), else a targeted reload by id.
  defp resolve_org_id(changeset, result, record_id) do
    [
      Ash.Changeset.get_attribute(changeset, :org_id),
      Map.get(result, :org_id)
    ]
    |> Enum.find(&usable?/1)
    |> case do
      nil -> reload_org_id(changeset.resource, record_id)
      val -> val
    end
  end

  defp reload_org_id(_resource, nil), do: nil

  defp reload_org_id(resource, id) do
    import Ash.Query

    resource
    |> filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [r | _] -> Map.get(r, :org_id)
      [] -> nil
    end
  rescue
    _ -> nil
  end

  defp usable?(%Ash.NotLoaded{}), do: false
  defp usable?(nil), do: false
  defp usable?(_), do: true

  defp get(record, key), do: Map.get(record, key)
  defp to_s(nil), do: nil
  defp to_s(v), do: to_string(v)
end
