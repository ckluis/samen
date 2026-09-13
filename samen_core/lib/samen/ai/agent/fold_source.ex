defmodule Samen.AI.Agent.FoldSource do
  @moduledoc """
  `Samen.AI.Agent.FoldSource` — ADR-048 §7.3's PSEUDONYM-KEYED PROVENANCE INDEX.

  One row per `{run, fold, source subject}` citation. The row exists so the §7.3
  withdrawal walk can find every fold that cites an erased subject **without decrypting a
  single transcript**: the index lives OUTSIDE the sealed body (a separate table, a
  separate resource — `Samen.AI.Agent.Run` still declares exactly ONE
  `pii_attribute(:transcript, …)` and gains no second sealed field), and it is keyed on a
  token, never on a value.

  ## Why the key is the DEK-keyed pseudonym and not the subject id

  `afs_subject_ref` is `Base.encode16(Samen.Vault.pseudonym(subject_id), case: :lower)` —
  the `HMAC(psk_S, subject_id)` whose key `psk_S` is HKDF-derived from the subject's OWN
  DEK (`Samen.Kms.Crypto.pseudonym/2`). That single choice is what makes the index
  self-erasing:

    * before the shred the pseudonym is computable, so the walk resolves its own targets;
    * after the shred the DEK is destroyed, so the pseudonym can NEVER be recomputed and
      every surviving row is permanently unlinkable to the person.

  §7.3 therefore **keeps the rows and kills the key** — it does not delete them. A build
  that deleted the index on shred would satisfy a naive "no rows remain" check while
  proving nothing about unlinkability, which is why ADR-048 §8 `P8` is asserted ON THE
  PSEUDONYM. The `email_bidx` failure mode (ADR-046 §4.1 D1) is the opposite shape and the
  reason this column may never hold a raw `subject_id`: a blind index is keyed on the
  shared, permanently un-shreddable `sys:bidx`, so key-shred does not reach it and it needs
  its own tombstoning arm. A DEK-keyed pseudonym needs none.

  ## What the erasure arm does write

  `withdraw_subject/3` is the ADR-048 §7.3 step-3 arm `Samen.Erasure` runs INSIDE the
  steps-2–5 `Ecto.Multi`, keyed on the pseudonym the caller captured **before**
  `Samen.Kms.shred/1` destroyed the DEK (ADR-046's envelope is untouched: key destruction
  still runs FIRST and OUTSIDE the transaction). It NEUTRALIZES — stamps
  `afs_withdrawn_at` — it never deletes.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "afs"

  @table "ai_agent_fold_source"

  postgres do
    table(@table)
    repo(Application.compile_env(:samen_core, :samen_ai_agent_fold_source_repo, SamenCore.TestRepo))
  end

  attributes do
    attribute(:run_id, :uuid, public?: true, allow_nil?: false)
    attribute(:fold_n, :integer, public?: true, allow_nil?: false)

    # The TOKEN. Never a subject id, never a value — see the moduledoc.
    attribute(:subject_ref, :string, public?: true, allow_nil?: false)

    # §7.3 step 3: the neutralizing stamp. Set by `withdraw_subject/3` when the subject
    # behind `subject_ref` is erased. The row survives; only the key that resolves it dies.
    attribute(:withdrawn_at, :utc_datetime_usec, public?: true)
  end

  identities do
    identity(:run_fold_ref, [:run_id, :fold_n, :subject_ref])
  end

  actions do
    defaults([:read])

    create :record do
      description(
        "Index one {run, fold, pseudonym} citation. Derived from the fold ledger at the " <>
          "single accepted persistence chokepoint; kernel-only."
      )

      accept([:org_id, :run_id, :fold_n, :subject_ref])
      upsert?(true)
      upsert_identity(:run_fold_ref)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    # Kernel-only writes (the Samen.AI.Agent.Run / Samen.AI.Agent.Turn posture).
    policy action_type([:create, :update, :destroy]) do
      authorize_if(always())
    end
  end

  # ===========================================================================
  # The ledger → index projection (called from Samen.AI.Agent.Run's changes block)
  # ===========================================================================

  @doc """
  Project the fold ledger carried by a transcript write into the provenance index.

  Registered as a resource-level change on `Samen.AI.Agent.Run`, so EVERY accepted
  transcript persistence keeps the index in step by construction — there is no second
  write path a fold could arrive through and skip it. The plaintext JSON is read at
  `change/3` time (before `Samen.Vault.Change`'s `before_action` swaps the attribute for
  its `vt_*` token) and the rows are written in an `after_action`, inside the SAME action
  transaction as the run row itself.

  Refs are copied out of the ledger's own `sources[].markers[].subject_ref`; the ledger
  writer (`Samen.AI.Agent.Compaction.source_marker/3`) is what mints them from the live
  DEK. A malformed ledger indexes nothing rather than guessing.
  """
  @spec index_change(Ash.Changeset.t()) :: Ash.Changeset.t()
  def index_change(changeset) do
    case Ash.Changeset.get_attribute(changeset, :transcript) do
      json when is_binary(json) ->
        case citations(json) do
          [] ->
            changeset

          citations ->
            # The org is read HERE, off the changeset, because the record an
            # `after_action` receives carries only what the data layer selected — on an
            # `:advance` that is not `org_id`.
            org_id = loaded(Ash.Changeset.get_attribute(changeset, :org_id))

            Ash.Changeset.after_action(changeset, fn _cs, record ->
              :ok = index_citations(record, org_id || loaded(record.org_id), citations)
              {:ok, record}
            end)
        end

      _ ->
        changeset
    end
  end

  defp loaded(%Ash.NotLoaded{}), do: nil
  defp loaded(value), do: value

  @doc """
  The `{fold_n, subject_ref}` citations a transcript's §7.3 fold ledger carries.

  Token-only by construction: it reads exactly `folds[].n` and
  `folds[].sources[].markers[].subject_ref` and nothing else — never a summary, never a
  record id, never a value.
  """
  @spec citations(String.t()) :: [{integer(), String.t()}]
  def citations(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"folds" => folds}} when is_list(folds) ->
        folds
        |> Enum.flat_map(&fold_citations/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp fold_citations(%{"n" => n} = fold) when is_integer(n) do
    fold
    |> Map.get("sources", [])
    |> List.wrap()
    |> Enum.flat_map(fn source -> source |> Map.get("markers", []) |> List.wrap() end)
    |> Enum.flat_map(fn
      %{"subject_ref" => ref} when is_binary(ref) and ref != "" -> [{n, ref}]
      _ -> []
    end)
  end

  defp fold_citations(_), do: []

  # Fail-honest: a citation whose org cannot be resolved is NOT indexed silently under a
  # guessed org — it raises, because an index the walk cannot trust is worse than none.
  defp index_citations(_record, nil, _citations) do
    raise ArgumentError,
          "Samen.AI.Agent.FoldSource: cannot index a fold ledger without the run's org_id"
  end

  defp index_citations(record, org_id, citations) do
    Enum.each(citations, fn {n, ref} ->
      __MODULE__
      |> Ash.Changeset.for_create(:record, %{
        org_id: org_id,
        run_id: record.id,
        fold_n: n,
        subject_ref: ref
      })
      |> Ash.create!(authorize?: false)
    end)

    :ok
  end

  # ===========================================================================
  # The ADR-048 §7.3 step-3 erasure arm
  # ===========================================================================

  @doc """
  NEUTRALIZE every index row keyed by `subject_ref` — ADR-048 §7.3 step 3.

  Called from `Samen.Erasure`'s steps-2–5 `Ecto.Multi` with the hex `subject_ref` derived
  from the pseudonym the caller captured BEFORE `Samen.Kms.shred/1` ran (after it, the
  pseudonym is uncomputable — which is the property `P8` asserts). Rows are STAMPED, never
  deleted.

  Returns `%{table: :present | :absent, rows_withdrawn: n}`. `:absent` is the honest
  answer for a host that mounts `Samen.Erasure` but not `Samen.AI.Domain` — it reports the
  skip rather than pretending it withdrew rows it never saw.
  """
  @spec withdraw_subject(String.t(), Ecto.Repo.t(), keyword()) :: %{
          table: :present | :absent,
          rows_withdrawn: non_neg_integer()
        }
  def withdraw_subject(subject_ref, repo, opts \\ []) when is_binary(subject_ref) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if table_present?(repo) do
      {:ok, %{num_rows: n}} =
        Ecto.Adapters.SQL.query(
          repo,
          "UPDATE #{@table} SET afs_withdrawn_at = $1, afs_updated_at = $2 " <>
            "WHERE afs_subject_ref = $3 AND afs_withdrawn_at IS NULL",
          [now, DateTime.truncate(now, :second), subject_ref]
        )

      %{table: :present, rows_withdrawn: n}
    else
      %{table: :absent, rows_withdrawn: 0}
    end
  end

  @doc """
  Every distinct run id whose ledger cites `subject_ref` — the §7.3 walk's OWN target set.

  This is what lets `Samen.AI.Agent.Compaction.withdraw/2` be a walk over the runs that
  actually cite the subject rather than a scan of every transcript in the host: the index
  is keyed on the pseudonym, so the targets resolve WITHOUT decrypting anything, and only
  those runs are ever opened. `:absent` table (a host that mounts `Samen.Erasure` but not
  `Samen.AI.Domain`) is an honest empty list, never a raised error.
  """
  @spec run_ids_citing(String.t(), Ecto.Repo.t()) :: [String.t()]
  def run_ids_citing(subject_ref, repo) when is_binary(subject_ref) do
    if table_present?(repo) do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          repo,
          "SELECT DISTINCT afs_run_id::text FROM #{@table} WHERE afs_subject_ref = $1",
          [subject_ref]
        )

      Enum.map(rows, fn [id] -> id end)
    else
      []
    end
  end

  @doc """
  Does this run hold at least one WITHDRAWN citation? — ADR-048 §7.3 step 5 / §8 `P14`.

  The run loop asks this at every turn boundary. It is deliberately a question about the
  INDEX (`afs_withdrawn_at IS NOT NULL`), not about whether a fold body carries the step-3
  marker: the marker is `P7`'s claim, and a run must terminate on its next turn even if the
  ledger rewrite is the half that failed. Fail-open ONLY when the table does not exist —
  a host with no index has no folds to withdraw, and terminating every run there would be
  a fail-closed posture with no fact behind it.
  """
  @spec withdrawn?(String.t(), Ecto.Repo.t()) :: boolean()
  def withdrawn?(run_id, repo) when is_binary(run_id) do
    if table_present?(repo) do
      {:ok, %{rows: [[n]]}} =
        Ecto.Adapters.SQL.query(
          repo,
          "SELECT count(*) FROM #{@table} " <>
            "WHERE afs_run_id = $1::text::uuid AND afs_withdrawn_at IS NOT NULL",
          [run_id]
        )

      n > 0
    else
      false
    end
  end

  defp table_present?(repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT to_regclass($1)", [@table]) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, %{rows: [[_]]}} -> true
      _ -> false
    end
  end
end
