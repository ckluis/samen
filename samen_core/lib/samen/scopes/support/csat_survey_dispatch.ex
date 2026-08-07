defmodule Samen.Scopes.Support.CsatSurveyDispatch do
  @moduledoc """
  I6 (spec §I6, T79) — an Ash change attached to `Ticket`'s `changes do end`
  block (`Samen.Scopes.Support.Blueprint.define_ticket/9`). When a ticket
  TRANSITIONS into `:resolved` (from any other status — never on a create at
  `:resolved`, never on a no-op resolved→resolved update), this:

    1. Sets `resolved_at` (only if not already set) as part of the SAME atomic
       write — closes a pre-existing substrate gap: no sanctioned write path
       (`Samen.Web.Support.Reads.update_ticket_status/4` included) ever set
       `resolved_at` before this task, so the `solved_this_week` metric
       (`Reads.metrics/2`) silently under-counted every real resolution.
    2. Best-effort, AFTER the write's transaction COMMITS
       (`Ash.Changeset.after_transaction/2` — deliberately NOT `after_action`,
       which runs INSIDE the transaction: holding it open across a real
       network send is bad practice, and a raised/failed send there would
       abort the primary status write itself, violating the "never aborts the
       primary write" contract every other Delivery consumer in this codebase
       honors — `Samen.Delivery.Lifecycle`, `Samen.Notifications.StatusChange`),
       mints + dispatches a CSAT survey via
       `Samen.Scopes.Support.CsatSurvey.send_survey/3`.

  Mirrors `Samen.Notifications.StatusChange`'s `changing_attribute?/2` +
  allow-listed-target-status shape (generalized here to a real chokepoint send
  instead of an in-app notification) and the `Samen.Delivery.Lifecycle`
  "rides alongside a primary write, never aborts it" posture.

  ## opts

    * `:csat_survey_token` — the host's `CsatSurveyToken` resource module
      (threaded at blueprint-expansion time, `Module.concat(namespace,
      CsatSurveyToken)` — see `Samen.Scopes.Support.__using__/1`)
    * `:csat` — the host's `Csat` resource module (same threading)
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> maybe_set_resolved_at()
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      if transitioning_to_resolved?(changeset) do
        maybe_dispatch(result, opts)
      end

      result
    end)
  end

  defp maybe_set_resolved_at(changeset) do
    if transitioning_to_resolved?(changeset) and
         is_nil(Ash.Changeset.get_attribute(changeset, :resolved_at)) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :resolved_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      changeset
    end
  end

  # `:status` is actually changing on THIS changeset AND the new value is
  # `:resolved` AND the PERSISTED (pre-write) value was NOT already `:resolved`
  # — a ticket bouncing resolved→resolved (e.g. an unrelated field edit that
  # happens to re-submit the same status) fires nothing, matching
  # `Samen.Notifications.StatusChange`'s exact discipline.
  defp transitioning_to_resolved?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :status) and
      Ash.Changeset.get_attribute(changeset, :status) == :resolved and
      previous_status(changeset) != :resolved
  end

  defp previous_status(%{data: %{status: status}}), do: status
  defp previous_status(_), do: nil

  defp maybe_dispatch({:error, _reason}, _opts), do: :ok

  defp maybe_dispatch({:ok, ticket}, opts) do
    csat_survey_token_mod = Keyword.fetch!(opts, :csat_survey_token)
    csat_mod = Keyword.fetch!(opts, :csat)

    case org_id_of(ticket) do
      nil ->
        # Unresolvable org_id (should not happen for a persisted ticket) —
        # honest skip, never a crash. Best-effort by contract.
        :ok

      org_id ->
        Samen.Scopes.Support.CsatSurvey.send_survey(
          %{csat_survey_token: csat_survey_token_mod, csat: csat_mod},
          %{ticket | org_id: org_id}
        )
    end

    :ok
  rescue
    e ->
      # Best-effort by contract: NOTHING here may retroactively affect the
      # already-committed primary write. `send_survey/3` itself never raises
      # (its own moduledoc/rescue guarantee this belt covers introspection
      # around it, e.g. a malformed `ticket` struct).
      Logger.warning(
        "[CsatSurveyDispatch] send_survey RAISED (primary write already committed, " <>
          "unaffected): #{Exception.message(e)}"
      )

      :ok
  end

  # `org_id` is NOT select-by-default on Samen resources (`Samen.Transformers.
  # CoreAttributes`) — an `:update` action's returned struct commonly carries
  # `#Ash.NotLoaded{}` for it unless the action's own changeset selected it.
  # Mirrors `Samen.Notifications.StatusChange.org_id_of/2`'s exact fallback: a
  # narrow re-select by primary key. `nil` (unresolvable) skips the dispatch
  # rather than crashing.
  defp org_id_of(%{org_id: org_id}) when is_binary(org_id), do: org_id

  defp org_id_of(%resource{id: id}) when is_binary(id) do
    resource
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  defp org_id_of(_), do: nil
end
