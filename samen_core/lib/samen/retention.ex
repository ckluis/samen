defmodule Samen.Retention do
  @moduledoc """
  Per-scope retention / TTL enforcement (F3.2). Turns "data lives forever unless a
  subject asks for erasure" into "each data class has a documented lifetime, and a
  worker enforces it" — the missing lifecycle half of the privacy story (today only
  the Oban pruner trims job rows at 7d; domain data had no TTL).

  ## Spec-driven, framework-first

  The framework does not know a host's resource modules, so retention is expressed as
  a list of `Samen.Retention.Spec` structs the HOST registers (app config
  `:samen_core, :retention_specs`), exactly like the rollup-erasure spec registry.
  Each spec says: *for this resource, rows whose `timestamp_field` is older than
  `ttl_seconds` are swept via `action`.*

  Two actions:

    * `:shred`  — the resource is subject-bearing (has vaulted PII). Each distinct
      `subject_field` value on an expired row is crypto-shredded via
      `Samen.Erasure.shred/2` — the key-destruction guarantee, not a copy-chase. The
      row's ciphertext becomes undecryptable everywhere at once. (Subscribers.)
    * `:delete` — the resource carries no subject key of its own (or is a pure
      event/log row); expired rows are hard-deleted (pruned). (Files/messages/tickets
      whose subject is erased via their parent, or whose retention is a straight prune.)

  ## Fail-closed cutoff — the load-bearing safety

  A spec with a non-positive / non-integer `ttl_seconds` is REFUSED (skipped, logged):
  a zero/`nil` TTL would sweep the WHOLE table. Retention only ever deletes rows
  strictly older than a positive TTL — never "all rows". `cutoff/2` computes the wall
  (`now - ttl`); the sweep filters `timestamp_field <= cutoff`, so a row exactly at
  its TTL edge is swept and a fresher row is retained. This is the guarantee the trio
  proves (an over-TTL row IS swept; an in-TTL row is NEVER touched) and the sabotage
  flips.

  ## Documented defaults

  `default_ttl_seconds/0` gives the recommended per-class defaults a host starts from
  (files 365d · messages 180d · tickets 365d · subscribers 730d). They are DEFAULTS,
  not enforced values — a host sets its own retention in config; these document intent.
  """

  require Ash.Query
  require Logger

  alias Samen.Retention.Spec

  @doc "Recommended default TTLs per data class (seconds). Documentation, not enforcement."
  @spec default_ttl_seconds() :: %{atom() => pos_integer()}
  def default_ttl_seconds do
    day = 24 * 60 * 60

    %{
      files: 365 * day,
      messages: 180 * day,
      tickets: 365 * day,
      subscribers: 730 * day
    }
  end

  @doc "The retention cutoff wall for a TTL at `now`: rows at/before this instant are expired."
  @spec cutoff(pos_integer(), DateTime.t()) :: DateTime.t()
  def cutoff(ttl_seconds, now) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    DateTime.add(now, -ttl_seconds, :second)
  end

  @doc """
  Sweep every spec. Returns `%{swept: total, by_spec: [%{resource, action, swept}]}`.

  `opts`:
    * `:now`  — the sweep instant (defaults to `DateTime.utc_now/0`; tests pin it).
    * `:repo` — forwarded to the shred path (`Samen.Erasure.shred/2`).

  A spec with an invalid TTL is skipped (fail-closed) and contributes `swept: 0`.
  Emits `[:samen, :retention, :sweep]` telemetry with `%{swept: total, specs: n}`.
  """
  @spec sweep([Spec.t()], keyword()) :: %{swept: non_neg_integer(), by_spec: [map()]}
  def sweep(specs, opts \\ []) when is_list(specs) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    by_spec =
      Enum.map(specs, fn spec ->
        spec = Spec.normalize(spec)
        swept = sweep_one(spec, now, opts)
        %{resource: spec.resource, action: spec.action, swept: swept}
      end)

    total = Enum.reduce(by_spec, 0, &(&1.swept + &2))

    :telemetry.execute([:samen, :retention, :sweep], %{swept: total, specs: length(specs)}, %{})

    %{swept: total, by_spec: by_spec}
  end

  # A single spec. Refuse an invalid TTL (fail-closed — never sweep the whole table).
  defp sweep_one(%Spec{ttl_seconds: ttl} = spec, _now, _opts)
       when not (is_integer(ttl) and ttl > 0) do
    Logger.error(
      "[Samen.Retention] REFUSING spec for #{inspect(spec.resource)} — invalid ttl_seconds " <>
        "#{inspect(ttl)} (a non-positive TTL would sweep the whole table). Skipped."
    )

    0
  end

  defp sweep_one(%Spec{action: :delete} = spec, now, _opts) do
    wall = cutoff(spec.ttl_seconds, now)

    expired =
      expired_query(spec, wall)
      |> Ash.read!(authorize?: false)

    Enum.reduce(expired, 0, fn row, acc ->
      Ash.destroy!(row, authorize?: false)
      acc + 1
    end)
  rescue
    e ->
      Logger.error("[Samen.Retention] delete sweep failed for #{inspect(spec.resource)}: #{inspect(e)}")
      0
  end

  defp sweep_one(%Spec{action: :shred} = spec, now, opts) do
    wall = cutoff(spec.ttl_seconds, now)
    repo = Keyword.get(opts, :repo)

    subjects =
      expired_query(spec, wall)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&Map.get(&1, spec.subject_field))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    Enum.reduce(subjects, 0, fn subject_id, acc ->
      shred_opts = if repo, do: [repo: repo], else: []

      case Samen.Erasure.shred(subject_id, shred_opts) do
        {:ok, _} -> acc + 1
        {:error, _} -> acc
      end
    end)
  rescue
    e ->
      Logger.error("[Samen.Retention] shred sweep failed for #{inspect(spec.resource)}: #{inspect(e)}")
      0
  end

  # Rows whose retention timestamp is at/before the wall — the expired set. The field
  # is dynamic (a spec may retain on :inserted_at, :closed_at, :last_activity_at, …).
  defp expired_query(%Spec{resource: resource, timestamp_field: field}, wall) do
    require Ash.Query
    Ash.Query.filter(resource, ^Ash.Expr.ref(field) <= ^wall)
  end
end
