defmodule Samen.Policy.RecipientOnly do
  @moduledoc """
  The per-recipient sibling of `Samen.Policy.OrgScope` and `Samen.Policy.OwnerOnly`: it narrows a
  per-recipient resource (a notification, a notification preference) to the rows whose
  `recipient_id` is the acting user's `id`. Stacked with `OrgScope` the two FilterChecks AND together.

  On a read another recipient's rows do not exist (`[]`, no existence oracle); on a write it
  authorizes only when the row's `recipient_id` equals the actor's `id`, so a create naming
  another recipient, or an update or destroy of another recipient's row, is refused. An actor
  with no `id` matches nothing (fail closed).

  ## `operator_reads: true`

  The operator (impersonation) plane reads a tenant's notifications masked (`PiiResolution`
  renders `••••`). A READ policy passes `operator_reads: true` so an actor whose `kind` is
  `:operator` sees every row of the org it is acting on (`OrgScope` still pins the org). It never
  widens a write: a write policy omits the option, and an operator is then refused like any other
  non-recipient.

  ## `org_addressed: true`

  The engine addresses system events (an invoice opened, an SLA breach, a send blocked) to the
  ORGANISATION: those rows have `recipient_id == org_id`. With this option a member (rank `:member`
  or above) also matches the rows addressed to the org the actor acts in; a viewer matches only
  their own. A user-addressed row is still reachable by its recipient alone.

  ## The tenant plane's broker actor

  `Samen.Web.Plane.scope/2` builds a tenant actor whose `id` is `"broker:<org>"`, which names no
  user and is no recipient. A per-recipient surface must build its scope with the REAL user id
  (`Samen.Web.Settings.Reads.user_scope/3`); under the bare broker it matches nothing.
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts) do
    if Keyword.get(opts, :operator_reads, false),
      do: "record.recipient_id == actor.id (the operator plane reads the whole org)",
      else: "record.recipient_id == actor.id (per-recipient isolation)"
  end

  @impl true
  def filter(actor, _context, opts) do
    if Keyword.get(opts, :operator_reads, false) and operator?(actor) do
      expr(true)
    else
      case ids(actor, opts) do
        [] -> expr(false)
        [id] -> expr(recipient_id == ^id)
        [id, org_id] -> expr(recipient_id == ^id or recipient_id == ^org_id)
      end
    end
  end

  @impl true
  def reject(actor, _context, opts) do
    if Keyword.get(opts, :operator_reads, false) and operator?(actor) do
      expr(false)
    else
      case ids(actor, opts) do
        [] -> expr(true)
        [id] -> expr(recipient_id != ^id or is_nil(recipient_id))
        [id, org_id] -> expr((recipient_id != ^id and recipient_id != ^org_id) or is_nil(recipient_id))
      end
    end
  end

  # The recipient ids this actor matches, UUIDs only: the tenant plane's broker actor id
  # (`"broker:<org>"`) names no user and is not a UUID, so it matches no user-addressed row (and a
  # non-UUID value would otherwise make the whole query fail its type cast).
  defp ids(actor, opts) when is_map(actor) do
    user = uuid(Map.get(actor, :id))

    org =
      if Keyword.get(opts, :org_addressed, false) and
           Samen.Scope.Role.at_least?(Map.get(actor, :role), :member),
         do: uuid(Map.get(actor, :org_id))

    Enum.reject([user, org], &is_nil/1)
  end

  defp ids(_actor, _opts), do: []

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_), do: nil

  defp operator?(actor) when is_map(actor), do: Map.get(actor, :kind) == :operator
  defp operator?(_), do: false

end
