defmodule Samen.Marketing.Consent do
  @moduledoc """
  Consent state DERIVED from the append-only `Marketing.ConsentEvent` ledger (F3 Unit 1)
  — the source of truth for whether a subscriber may be contacted.

  The mutable `consent_at` column on `Subscriber` is a convenience cache that can drift;
  this ledger cannot (it is append-only, one row per transition). `state/3` folds a
  subscriber's rows **latest-event-wins** into a bounded verdict:

    * `:granted`  — the most recent event is `:granted`
    * `:withdrawn` — the most recent event is `:withdrawn` (do-not-contact)
    * `:none`     — no consent events recorded

  ## Survives erasure

  Because the ledger is never touched by `Samen.Erasure.shred/2` (it carries no vaulted
  PII — only bounded ids/enums + a keyed pseudonym), a `:withdrawn` verdict is honored
  after the subject's email is crypto-shredded. "Do-not-contact" outlives the PII.

  The read is `OrgScope`-bounded through the mounted event resource, so a caller only
  ever sees its own org's consent history.
  """

  require Ash.Query

  @doc """
  Derive the current consent state for `subscriber_id` in `org_id` from the mounted
  `event_resource` (the host's `Marketing.ConsentEvent`). Latest-event-wins.

  Reads with `authorize?: false` (a framework-internal derivation, like the ledger's
  own emit) but is explicitly bounded to `org_id` + `subscriber_id`, so it never
  crosses an org boundary. Returns `:granted | :withdrawn | :none`; fails closed to
  `:none` if the ledger cannot be read (never fabricates `:granted`).
  """
  @spec state(module(), String.t() | binary(), String.t() | binary()) ::
          :granted | :withdrawn | :none
  def state(event_resource, org_id, subscriber_id) do
    event_resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.filter(subscriber_id == ^subscriber_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{event: :granted} | _] -> :granted
      [%{event: :withdrawn} | _] -> :withdrawn
      _ -> :none
    end
  rescue
    _ -> :none
  end
end
