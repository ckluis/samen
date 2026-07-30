defmodule Samen.Delivery.EmailEvent do
  @moduledoc """
  The `dlv_email_event` deliverability-event store (ADR-038 §4.4; C4, T30).

  ONE governed core resource, backing the "matched deliverability event" side of
  C4 — like `Samen.Webhook.Event`, a plain `Ecto.Schema` (NOT a per-tenant Ash
  blueprint) written through raw Ecto, because a delivery family's recipient is
  an opaque token that varies by family (a marketing `Subscriber`, an
  `Identity.User`, …) and this table must stay family-agnostic (INV-4;
  framework-first, vendor-generic).

  ## Token-only by construction (ADR-038 §4.4)

  Columns are `send_id` / `org_id` / `subscriber_id` (all opaque refs), `kind`,
  `provider`, `provider_message_id`, `provider_event_id`, `occurred_at`. There is
  NO payload column here — the (already-redacted) raw payload stays on the
  `Samen.Webhook.Event` envelope that produced this row; `EmailEvent` is the
  MATCHED, token-blind projection of it (never the raw vendor payload; never an
  email address — recipient matching goes `provider_message_id -> send receipt
  -> subscriber ref`, never by address).

  ## Idempotent by construction

  `{provider, provider_event_id}` carries a UNIQUE index — the same replay-arbiter
  shape as `Samen.Webhook.Event`'s `{provider, event_id}` index. A webhook
  processing retry (idempotent per ADR-038 §4.4/§5.2) that re-dispatches the SAME
  underlying vendor event is therefore a safe no-op here too, not a duplicate row.

  ## Columns (all `dlv_`-prefixed — the self-qualifying storage idiom)

    * `provider` — the vendor atom-as-string (e.g. the adapter's provider name)
    * `provider_event_id` — the vendor's `ProviderEvent.event_id` (replay key)
    * `provider_message_id` — the token-blind join key (ADR-038 §4.1/§4.4)
    * `kind` — `delivered | bounce | complaint | open | click`
    * `send_id` / `org_id` / `subscriber_id` — opaque refs from the matched receipt
    * `occurred_at` — the provider's event timestamp
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  @type t :: %__MODULE__{}

  @kinds ~w(delivered bounce complaint open click)
  @unique_index_name "dlv_email_event_provider_event_id_index"

  # abbrev: "dlv" — kernel infra, exempt from the abbrev registry (not an
  # `Ash.Resource.Info`-visible resource; the `whk_event`/`aud_event` precedent).
  @primary_key {:id, :binary_id, autogenerate: true, source: :dlv_id}
  schema "dlv_email_event" do
    field(:provider, :string, source: :dlv_provider)
    field(:provider_event_id, :string, source: :dlv_provider_event_id)
    field(:provider_message_id, :string, source: :dlv_provider_message_id)
    field(:kind, :string, source: :dlv_kind)
    field(:send_id, :binary_id, source: :dlv_send_id)
    field(:org_id, :binary_id, source: :dlv_org_id)
    field(:subscriber_id, :binary_id, source: :dlv_subscriber_id)
    field(:occurred_at, :utc_datetime_usec, source: :dlv_occurred_at)
    field(:inserted_at, :utc_datetime_usec, source: :dlv_inserted_at, autogenerate: {__MODULE__, :now, []})
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc "The bounded kind values."
  def kinds, do: @kinds

  @doc """
  Idempotently record a matched deliverability event. `attrs` MUST already carry
  the matched `:send_id`/`:org_id`/`:subscriber_id` refs (this function never
  matches — see `Samen.Delivery.Deliverability`).

  Returns `{:ok, :inserted, row}` on a first delivery or `{:ok, :duplicate,
  existing}` on a replay (the `{provider, provider_event_id}` unique index is the
  arbiter — a concurrency-safe no-op, never a raise).
  """
  @spec record(module(), map()) ::
          {:ok, :inserted, t()} | {:ok, :duplicate, t()} | {:error, Ecto.Changeset.t()}
  def record(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = normalize(attrs)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        attrs,
        [:provider, :provider_event_id, :provider_message_id, :kind, :send_id, :org_id, :subscriber_id, :occurred_at]
      )
      |> Ecto.Changeset.validate_required([:provider, :provider_event_id, :kind, :org_id, :subscriber_id, :occurred_at])
      |> Ecto.Changeset.validate_inclusion(:kind, @kinds)
      |> Ecto.Changeset.unique_constraint([:provider, :provider_event_id], name: @unique_index_name)

    case repo.insert(changeset) do
      {:ok, row} ->
        {:ok, :inserted, row}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if unique_violation?(errors) do
          {:ok, :duplicate, get_by_event(repo, attrs.provider, attrs.provider_event_id)}
        else
          {:error, cs}
        end
    end
  end

  @doc "Fetch one row by its `{provider, provider_event_id}` natural key."
  @spec get_by_event(module(), String.t(), String.t()) :: t() | nil
  def get_by_event(repo, provider, provider_event_id) when is_atom(repo) do
    repo.one(
      from(e in __MODULE__,
        where: e.provider == ^provider and e.provider_event_id == ^provider_event_id,
        limit: 1
      )
    )
  end

  @doc "All events recorded for `(org_id, subscriber_id)`, most-recent first."
  @spec list_for_subscriber(module(), String.t(), String.t()) :: [t()]
  def list_for_subscriber(repo, org_id, subscriber_id) when is_atom(repo) do
    repo.all(
      from(e in __MODULE__,
        where: e.org_id == ^org_id and e.subscriber_id == ^subscriber_id,
        order_by: [desc: e.occurred_at]
      )
    )
  end

  @doc """
  The operator per-tenant delivery TIMELINE (R2, T114): every event recorded for
  `org_id` across ALL subscribers, most-recent first, bounded. This is the "why
  didn't this tenant get their email" read — an operator drilling into ONE tenant
  org sees its whole delivery history (delivered/bounce/complaint/open/click), not
  just one subscriber's. Token-blind by construction (no PII column on this
  schema); a caller resolving "who" from `subscriber_id` does so through
  `Samen.Api.PiiResolution` against whatever family resource the id belongs to —
  never here.
  """
  @spec list_for_org(module(), String.t(), keyword()) :: [t()]
  def list_for_org(repo, org_id, opts \\ []) when is_atom(repo) do
    limit = Keyword.get(opts, :limit, 200)

    repo.all(
      from(e in __MODULE__,
        where: e.org_id == ^org_id,
        order_by: [desc: e.occurred_at],
        limit: ^limit
      )
    )
  end

  defp normalize(attrs), do: Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  defp unique_violation?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
