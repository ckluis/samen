defmodule Samen.Delivery.Suppression do
  @moduledoc """
  The `dlv_suppression` org-scoped delivery suppression list (ADR-038 §4.4; C4,
  T30) — the PRODUCTION backing store `Samen.Delivery.Chokepoint.suppressed?/2`
  points to via `Samen.Delivery.SuppressionCheck` (T28 named this the GAP: "no
  production host wires a real backing store for non-marketing families yet —
  mechanism proven via a test-injected fake only"; this module is that store).

  Like `Samen.Delivery.EmailEvent`, this is kernel infra backed by a plain
  `Ecto.Schema` (NOT a per-tenant Ash blueprint): the Chokepoint's suppression
  check is family-agnostic (`(org_id, subscriber_id)`, where `subscriber_id` may
  be a marketing `Subscriber`, an `Identity.User`, or any other family's
  recipient token), so the backing table cannot be scoped to one family's schema
  (framework-first, vendor/family-generic; INV-4).

  ## No PII (mirrors the Marketing.Suppression precedent)

  Every column is a bounded id or enum — `org_id`, `subscriber_id` (opaque
  refs), `reason` (`bounce | complaint | manual`), `source_provider` (nilable).
  No email address is ever stored here (matches `Samen.Scopes.Marketing.Blueprint`'s
  documented rule for its own `Suppression` resource: "Suppression rows carry
  only the opaque `subscriber_id` FK — no email address").

  ## Upsert semantics

  `suppress/2` is idempotent-by-upsert: `{org_id, subscriber_id}` carries a
  UNIQUE index. A second bounce/complaint for an already-suppressed recipient is
  a safe no-op (first reason wins; suppression is a boolean fact, not a counter).
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  @type t :: %__MODULE__{}

  @reasons ~w(bounce complaint manual)
  @unique_index_name "dlv_suppression_org_subscriber_index"

  # abbrev: "dlv" — kernel infra, exempt from the abbrev registry (shares the
  # prefix with `Samen.Delivery.EmailEvent`; distinct table names).
  @primary_key {:id, :binary_id, autogenerate: true, source: :dlv_id}
  schema "dlv_suppression" do
    field(:org_id, :binary_id, source: :dlv_org_id)
    field(:subscriber_id, :binary_id, source: :dlv_subscriber_id)
    field(:reason, :string, source: :dlv_reason)
    field(:source_provider, :string, source: :dlv_source_provider)
    field(:inserted_at, :utc_datetime_usec, source: :dlv_inserted_at, autogenerate: {__MODULE__, :now, []})
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc "The bounded reason values."
  def reasons, do: @reasons

  @doc """
  Suppress `(org_id, subscriber_id)`. Idempotent upsert: a repeat call for an
  already-suppressed pair is a safe no-op (`ON CONFLICT DO NOTHING`-shaped —
  the FIRST reason recorded wins, matching the fixed "suppression is a boolean
  fact" semantics `Samen.Scopes.Marketing.Blueprint`'s `Suppression` resource
  documents).
  """
  @spec suppress(module(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def suppress(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = normalize(attrs)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(attrs, [:org_id, :subscriber_id, :reason, :source_provider])
      |> Ecto.Changeset.validate_required([:org_id, :subscriber_id, :reason])
      |> Ecto.Changeset.validate_inclusion(:reason, @reasons)

    case changeset do
      %Ecto.Changeset{valid?: false} = cs ->
        {:error, cs}

      %Ecto.Changeset{valid?: true} ->
        repo.insert(changeset,
          on_conflict: :nothing,
          conflict_target: [:org_id, :subscriber_id]
        )

        # `on_conflict: :nothing` returns `{:ok, struct}` regardless of whether
        # the row was freshly inserted or a conflict was silently skipped (the
        # client-generated binary_id makes the struct's `:id` unreliable as a
        # signal either way) — re-read the AUTHORITATIVE row so the caller
        # always gets the real, persisted (first-reason-wins) fact.
        {:ok, get(repo, attrs.org_id, attrs.subscriber_id)}
    end
  end

  @doc "Is `(org_id, subscriber_id)` suppressed? Pure boolean read."
  @spec suppressed?(module(), String.t(), String.t()) :: boolean()
  def suppressed?(repo, org_id, subscriber_id) when is_atom(repo) do
    not is_nil(get(repo, org_id, subscriber_id))
  end

  @doc "Fetch the suppression row for `(org_id, subscriber_id)`, or nil."
  @spec get(module(), String.t(), String.t()) :: t() | nil
  def get(repo, org_id, subscriber_id) when is_atom(repo) do
    repo.one(
      from(s in __MODULE__,
        where: s.org_id == ^org_id and s.subscriber_id == ^subscriber_id,
        limit: 1
      )
    )
  end

  @doc """
  The operator per-tenant suppression LIST (R2, T114): every currently-suppressed
  `subscriber_id` for `org_id`, most-recently-suppressed first, bounded. Answers
  "who is suppressed, and why" for one tenant — the other half of the "why didn't
  this tenant get their email" read (`Samen.Delivery.EmailEvent.list_for_org/3` is
  the event-history half). No PII column exists here (see moduledoc); resolving
  "who" from `subscriber_id` is the caller's job, through `PiiResolution`.
  """
  @spec list_for_org(module(), String.t(), keyword()) :: [t()]
  def list_for_org(repo, org_id, opts \\ []) when is_atom(repo) do
    limit = Keyword.get(opts, :limit, 200)

    repo.all(
      from(s in __MODULE__,
        where: s.org_id == ^org_id,
        order_by: [desc: s.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc "Lift a suppression (operator/manual action). Idempotent — a no-op if absent."
  @spec lift(module(), String.t(), String.t()) :: :ok
  def lift(repo, org_id, subscriber_id) when is_atom(repo) do
    {_count, _} =
      repo.delete_all(from(s in __MODULE__, where: s.org_id == ^org_id and s.subscriber_id == ^subscriber_id))

    :ok
  end

  defp normalize(attrs), do: Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  @doc false
  def unique_index_name, do: @unique_index_name
end
