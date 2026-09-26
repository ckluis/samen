defmodule Samen.Billing.Meter do
  @moduledoc """
  The **usage-capture chokepoint** (T163; ADR-051 §2). `record/3` is the only
  sanctioned way to write a row into a host's `UsageEvent` ledger
  (`Samen.Scopes.Billing.Blueprint.define_usage_event/5`): the ledger's `:record`
  action carries `Samen.Billing.Meter.ChokepointGuard`, which refuses any create that
  did not come through here.

  ## Idempotent by the caller's event identity

  Every capture names the event it records with a `source_ref`, the caller's own
  stable identity for that event (`"api_call:<request_id>"`, `"message:<message_id>"`,
  `"seat:<membership_id>:<period>"`). The stored key is `idempotency_key/2`, a UUID
  derived from `metric` and `source_ref`. The same event captured twice (a retried
  job, a replayed webhook, a double-submitted request) therefore maps to the same
  key, and the ledger's `(org_id, idempotency_key)` identity turns the second capture
  into a no-op that answers `{:ok, :duplicate}`.

  A capture WITHOUT a `source_ref` is refused (`{:error, :idempotency_ref_required}`).
  It is never given a generated one: a random key is unique on every retry, which is
  exactly the double-count this ledger exists to remove (ADR-051 §2.3, R5).

  `source_ref` is hashed, never stored. It must still be an opaque id, not a name or
  an email: a low-entropy ref can be recovered from its hash by guessing.

  ## Safe inside the caller's transaction

  A replay is an upsert on the identity with no fields to change, not a caught
  unique-violation. Postgres aborts the enclosing transaction on a unique violation,
  so catching one would poison a caller that meters inside its own transaction; the
  upsert returns the existing row instead. `record/3` tells the two outcomes apart by
  the row id it assigned: the row that comes back is either the one it inserted or
  the one that was already there.

  ## What it does NOT do

  It never blocks capture on a quota (`within_limit?` is a separate read, ADR-051
  §2.6: usage that happened is recorded), never prices anything (the mirror
  doctrine, `Samen.Billing.Mirror`), and never writes the `Usage` tally (derived,
  ADR-051 P2).

      Samen.Billing.Meter.record(org_id, %{metric: :api_calls, quantity: 1,
        source_ref: "api_call:" <> request_id}, resource: MyApp.Billing.UsageEvent)
      #=> {:ok, :recorded}   # first capture
      #=> {:ok, :duplicate}  # the same event again
  """

  alias Samen.Billing.Meter.ChokepointGuard

  @type event :: %{
          required(:metric) => atom(),
          required(:quantity) => pos_integer(),
          required(:source_ref) => String.t(),
          optional(:subscription_id) => Ecto.UUID.t() | nil,
          optional(:occurred_at) => DateTime.t()
        }

  @doc """
  Record one usage event for `org_id` into the host ledger named by `opts[:resource]`.

  Returns `{:ok, :recorded}` for a new event, `{:ok, :duplicate}` when the same
  `(metric, source_ref)` was already captured for this org, or `{:error, reason}`
  (`:idempotency_ref_required`, `:invalid_metric`, `:invalid_org_id`, or the Ash
  error for an out-of-range value). Nothing is written on an error.
  """
  @spec record(Ecto.UUID.t(), event(), keyword()) ::
          {:ok, :recorded | :duplicate} | {:error, term()}
  def record(org_id, event, opts) when is_map(event) and is_list(opts) do
    resource = Keyword.fetch!(opts, :resource)

    with {:ok, org_id} <- cast_org_id(org_id),
         {:ok, metric} <- fetch_metric(event),
         {:ok, source_ref} <- fetch_source_ref(event) do
      id = Ecto.UUID.generate()

      attrs = %{
        metric: metric,
        quantity: Map.get(event, :quantity),
        subscription_id: Map.get(event, :subscription_id),
        idempotency_key: idempotency_key(metric, source_ref),
        occurred_at: Map.get(event, :occurred_at) || DateTime.utc_now(),
        org_id: org_id
      }

      resource
      |> Ash.Changeset.for_create(:record, attrs,
        upsert?: true,
        upsert_identity: :unique_idempotency_key,
        upsert_fields: [],
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.Changeset.set_context(%{private: %{ChokepointGuard.marker_key() => true}})
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, %{id: ^id}} -> {:ok, :recorded}
        {:ok, _existing} -> {:ok, :duplicate}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  The stored dedup key for `(metric, source_ref)`: the first 128 bits of
  `SHA-256(metric <> 0x00 <> source_ref)`, stamped as an RFC 9562 version-8 UUID.

  Deterministic, so a retry lands on the same key; a UUID, so the default-deny CDC
  classifier mirrors it as a bounded id (a string column would need a `non_pii!`
  clearance); keyed on the metric too, so one source event may be captured once per
  metric (a message that is both one `:messages` and one `:events`).
  """
  @spec idempotency_key(atom(), String.t()) :: Ecto.UUID.t()
  def idempotency_key(metric, source_ref) when is_atom(metric) and is_binary(source_ref) do
    <<a::48, _version::4, b::12, _variant::2, c::62, _rest::binary>> =
      :crypto.hash(:sha256, [Atom.to_string(metric), 0, source_ref])

    {:ok, uuid} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)
    uuid
  end

  defp cast_org_id(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_org_id}
    end
  end

  defp fetch_metric(event) do
    case Map.get(event, :metric) do
      metric when is_atom(metric) and metric not in [nil, true, false] -> {:ok, metric}
      _ -> {:error, :invalid_metric}
    end
  end

  defp fetch_source_ref(event) do
    case Map.get(event, :source_ref) do
      ref when is_binary(ref) and byte_size(ref) > 0 -> {:ok, ref}
      _ -> {:error, :idempotency_ref_required}
    end
  end
end
