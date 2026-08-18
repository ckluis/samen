defmodule Samen.Webhook.Event do
  @moduledoc """
  The `whk_event` webhook ingress replay-store + DLQ substrate (ADR-038 §5.3; T19/B9).

  ONE governed core resource backs both the replay-protection store and the
  dead-letter queue. It is kernel infrastructure — like `Samen.AuditEvent`, a plain
  `Ecto.Schema` (NOT a per-tenant Ash blueprint) written through raw Ecto so the
  vendor-generic ingress in `samen_web` can persist an envelope BEFORE any org is
  attributed (ingress happens ahead of auth; `whk_org_id` is nilable and resolved
  during processing).

  ## Columns (all `whk_`-prefixed — the self-qualifying storage idiom)

    * `provider` / `event_id` — the `{provider, event_id}` pair carries a UNIQUE index
      (`whk_event_provider_event_id_index`). This index is the replay arbiter: a
      duplicate delivery (even concurrent) collides at the DB and is a safe no-op
      (ADR-038 §5.2 step 3).
    * `kind` — the normalized samen-owned event kind (from the adapter's ProviderEvent).
    * `domain` — `"billing" | "delivery" | "unknown"`; the worker dispatches by it.
    * `occurred_at` — the provider's event timestamp.
    * `payload` — the ALREADY-REDACTED map (ADR-038 §5.4; the adapter's `redact_payload/1`
      ran before this row was written). NEVER carries emails/names/addresses/phone —
      INV-1. Replay never needs the pruned fields (billing re-fetches authoritative
      objects §3.4; delivery re-matches by `provider_message_id` §4.4).
    * `status` — `:received | :processing | :processed | :dead` (the DLQ state machine).
    * `attempt_count` / `last_error` — `last_error` is a message + digest ONLY, never a
      payload echo (§5.3).
    * `processed_at` — set when a terminal state is reached.
    * `org_id` — nilable; the org resolved DURING processing.

  ## Retention (ADR-038 §5.3)

  `:processed` rows prune after 30 days; `:dead` rows are kept until operator
  resolution. Pruning is the maintenance queue's job (`Samen.Webhook.Event.prune/2`
  is the query; wiring the cron belongs to the maintenance-queue owner).

  ## Write path (raw Ecto — works inside a `Multi` or standalone)

    * `insert_received/2` — insert an envelope; concurrency-safe replay detection via
      the unique index. Returns `{:ok, :inserted, row}` for a first delivery or
      `{:ok, :duplicate, existing}` for a replay.
    * `mark_processing/2`, `mark_processed/2`, `mark_dead/3`, `bump_attempt/2` — the
      DLQ state transitions used by `Samen.Webhook.IngestWorker`.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  @type t :: %__MODULE__{}

  @statuses ~w(received processing processed dead)
  @domains ~w(billing delivery unknown)

  @unique_index_name "whk_event_provider_event_id_index"

  # abbrev: "whk" — all columns carry the `whk_` prefix (self-qualifying storage idiom;
  # the aud_event precedent, Samen.AuditEvent).
  @primary_key {:id, :binary_id, autogenerate: true, source: :whk_id}
  schema "whk_event" do
    field(:provider, :string, source: :whk_provider)
    field(:event_id, :string, source: :whk_event_id)
    field(:kind, :string, source: :whk_kind)
    field(:domain, :string, source: :whk_domain, default: "unknown")
    field(:occurred_at, :utc_datetime_usec, source: :whk_occurred_at)
    field(:payload, :map, source: :whk_payload, default: %{})
    field(:status, :string, source: :whk_status, default: "received")
    field(:attempt_count, :integer, source: :whk_attempt_count, default: 0)
    field(:last_error, :string, source: :whk_last_error)
    field(:processed_at, :utc_datetime_usec, source: :whk_processed_at)
    field(:org_id, :binary_id, source: :whk_org_id)
    field(:inserted_at, :utc_datetime_usec, source: :whk_inserted_at, autogenerate: {__MODULE__, :now, []})
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc "The bounded status values (`received | processing | processed | dead`)."
  def statuses, do: @statuses

  @doc "The bounded domain values (`billing | delivery | unknown`)."
  def domains, do: @domains

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  @doc """
  Insert a received webhook envelope. `attrs` MUST carry an already-redacted
  `:payload` (the adapter's `redact_payload/1` has run — this function never
  redacts; storing raw PII would violate INV-1).

  Concurrency-safe replay protection: the `{provider, event_id}` unique index is
  the sole arbiter. Two racing duplicate deliveries → exactly one `:inserted`, the
  other `:duplicate` (the DB rejects the second; the changeset `unique_constraint`
  turns the violation into a value, never a raise).

  Returns `{:ok, :inserted, row}` | `{:ok, :duplicate, existing}` | `{:error, changeset}`.
  """
  @spec insert_received(module(), map()) ::
          {:ok, :inserted, t()} | {:ok, :duplicate, t()} | {:error, Ecto.Changeset.t()}
  def insert_received(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = normalize(attrs)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        attrs,
        [:provider, :event_id, :kind, :domain, :occurred_at, :payload, :org_id]
      )
      |> Ecto.Changeset.put_change(:status, "received")
      |> Ecto.Changeset.put_change(:attempt_count, 0)
      |> Ecto.Changeset.validate_required([:provider, :event_id, :kind, :occurred_at])
      |> Ecto.Changeset.validate_inclusion(:domain, @domains)
      |> Ecto.Changeset.unique_constraint([:provider, :event_id], name: @unique_index_name)

    case repo.insert(changeset) do
      {:ok, row} ->
        {:ok, :inserted, row}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if unique_violation?(errors) do
          {:ok, :duplicate, get_by_event(repo, attrs.provider, attrs.event_id)}
        else
          {:error, cs}
        end
    end
  end

  @doc "Transition an envelope to `:processing` and stamp an attempt."
  @spec mark_processing(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_processing(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(status: "processing", attempt_count: (row.attempt_count || 0) + 1)
    |> repo.update()
  end

  @doc "Transition an envelope to `:processed` (terminal success)."
  @spec mark_processed(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_processed(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(status: "processed", processed_at: now(), last_error: nil)
    |> repo.update()
  end

  @doc """
  Transition an envelope to `:dead` (the DLQ terminal). `error` is truncated to a
  message + digest — NEVER a payload echo (§5.3).
  """
  @spec mark_dead(module(), t(), term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_dead(repo, %__MODULE__{} = row, error) do
    row
    |> Ecto.Changeset.change(status: "dead", processed_at: now(), last_error: summarize_error(error))
    |> repo.update()
  end

  @doc "Reset a `:dead` (or any) envelope back to `:received` for an operator replay."
  @spec reset_for_replay(module(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def reset_for_replay(repo, %__MODULE__{} = row) do
    row
    |> Ecto.Changeset.change(status: "received", last_error: nil, processed_at: nil)
    |> repo.update()
  end

  # ---------------------------------------------------------------------------
  # Read path
  # ---------------------------------------------------------------------------

  @doc "Fetch one envelope by id (nil if absent)."
  @spec get(module(), String.t()) :: t() | nil
  def get(repo, id) when is_atom(repo), do: repo.get(__MODULE__, id)

  @doc """
  Fetch one envelope by id ONLY if it is in the DLQ's actionable state (`status == "dead"`)
  — the governed fetch for the operator replay/resolve WRITE paths (S14). The operator DLQ
  surface renders its mutation affordances exclusively on `:dead` rows, so the write path's
  read is bounded to that same set: a crafted event id naming a `:received`/`:processing`/
  `:processed` envelope reads `nil` here and the mutation never runs. Strictly narrower
  than `get/2` (which remains the ungated internal fetch for the ingest worker itself).
  """
  @spec get_dead(module(), String.t()) :: t() | nil
  def get_dead(repo, id) when is_atom(repo) do
    repo.one(from(e in __MODULE__, where: e.id == ^id and e.status == "dead", limit: 1))
  end

  @doc "Fetch one envelope by its `{provider, event_id}` natural key."
  @spec get_by_event(module(), String.t(), String.t()) :: t() | nil
  def get_by_event(repo, provider, event_id) when is_atom(repo) do
    repo.one(from(e in __MODULE__, where: e.provider == ^provider and e.event_id == ^event_id, limit: 1))
  end

  @doc """
  The operator DLQ listing (ADR-038 §5.5): `:dead` first, then recent envelopes,
  most-recent first, bounded. Token-blind by construction — every column returned
  is a bounded id/enum/timestamp/count or the already-redacted payload.

  T114/R5 fix: the case fragment maps `dead -> 0`, everything else `-> 1`; ORDER
  must be `asc` on that column so `0` (dead) sorts before `1` (else) — the
  previous `desc` inverted this (desc sorts `1` before `0`, putting dead rows
  LAST, contradicting this very docstring). The tiebreak (`desc: e.inserted_at`,
  most-recent first) is a SEPARATE `order_by` term, unaffected by the fix.
  """
  @spec list_for_operator(module(), keyword()) :: [t()]
  def list_for_operator(repo, opts \\ []) when is_atom(repo) do
    limit = Keyword.get(opts, :limit, 100)

    repo.all(
      from(e in __MODULE__,
        order_by: [
          asc: fragment("case when ? = 'dead' then 0 else 1 end", e.status),
          desc: e.inserted_at
        ],
        limit: ^limit
      )
    )
  end

  @doc "Query (not executed) for prunable `:processed` rows older than `older_than`."
  @spec prunable_processed(module(), DateTime.t()) :: [t()]
  def prunable_processed(repo, older_than) when is_atom(repo) do
    repo.all(
      from(e in __MODULE__, where: e.status == "processed" and e.inserted_at < ^older_than)
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_atom(k), v} end)
    |> Map.put_new(:domain, "unknown")
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  defp unique_violation?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # A message + short digest only — never the payload, never a subject-content string.
  defp summarize_error(error) do
    text =
      case error do
        e when is_binary(e) -> e
        %{__struct__: mod} = e -> "#{inspect(mod)}: #{Exception.message(e)}"
        other -> inspect(other)
      end

    text
    |> String.slice(0, 500)
  rescue
    _ -> "unprintable_error"
  end
end
