defmodule Samen.MultiNode.CountWorker do
  @moduledoc """
  L4 proof worker (T90). Each execution APPENDS one row to `mn_exec` keyed by the
  job's `"key"` arg and the executing node. "Exactly-once across nodes" then means:
  every enqueued key appears in `mn_exec` EXACTLY once. A double-grab (two nodes
  both claiming the same job — i.e. broken `SKIP LOCKED` fetch) shows up as a key
  with two rows. The detector is `Samen.MultiNode.Harness.duplicate_keys/0`.

  No `unique` here: the distinct-execution proof enqueues DISTINCT keys and asserts
  each ran once — that isolates the FETCH-level exactly-once (SKIP LOCKED), not
  insert-time dedup (which `UniqueWorker` covers).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key}}) do
    Samen.MultiNode.Repo.query!(
      "INSERT INTO mn_exec (job_key, node, worker) VALUES ($1, $2, $3)",
      [key, Atom.to_string(node()), "count"]
    )

    :ok
  end
end

defmodule Samen.MultiNode.UniqueWorker do
  @moduledoc """
  L4 uniqueness proof worker (T90). `unique` dedups at INSERT time: enqueuing the
  SAME `"key"` many times (from either node) collapses to ONE `oban_jobs` row, so
  the side effect fires ONCE. Contrast `NoUniqueWorker` (identical body, no
  `unique`) which is the negative control: the same fan-out fires N times. Together
  they prove the assertion is refutable — `unique` is doing real work, not a
  tautology.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:key], period: 300, states: Oban.Job.states()]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key}}) do
    Samen.MultiNode.Repo.query!(
      "INSERT INTO mn_exec (job_key, node, worker) VALUES ($1, $2, $3)",
      [key, Atom.to_string(node()), "unique"]
    )

    :ok
  end
end

defmodule Samen.MultiNode.NoUniqueWorker do
  @moduledoc "Negative control for `UniqueWorker` — identical body, NO `unique`."
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key}}) do
    Samen.MultiNode.Repo.query!(
      "INSERT INTO mn_exec (job_key, node, worker) VALUES ($1, $2, $3)",
      [key, Atom.to_string(node()), "nounique"]
    )

    :ok
  end
end
