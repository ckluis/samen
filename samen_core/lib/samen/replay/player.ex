defmodule Samen.Replay.Player do
  @moduledoc """
  The replay PLAYER kernel (ADR-052 §2.3): list, load and step through a stored session under
  the VIEWER's `%Samen.Scope{}`, and audit every open. The web player
  (`Samen.Web.Replay.PlayerLive`) decides WHO may watch (`Samen.Web.Replay.Access`) and renders;
  this module never decides authorization and never renders.

    * `list/2` — bounded session METADATA (ids, view module, timing, counters), newest first,
      read under the viewer's scope (`Samen.Policy.OrgScope` on `Samen.Replay.Session`).
    * `load/3` — one session and its frames, read under the viewer's scope (a session of
      another org is `{:error, :not_found}`), each frame decoded by `Samen.Replay.Decoder`
      (schema re-checked, no atom created). The decoded frames hold REFERENCES, never values.
    * `assigns_at/2` — the assigns a frame showed: the mount frame's assigns, then each later
      render frame's changed assigns merged on top (frames record only `__changed__`).
    * `resolve/3` — `Samen.Replay.Resolver` over those assigns, on the viewer's plane, NOW.
    * `drift/1` — the code-drift marker: the stored view MD5 against the loaded module.
    * `timeline/1` — bounded frame labels and the recorded gaps.
    * `audit_viewed/2` — the ONE token-only `aud_event` (`replay.viewed`) an open writes.
  """

  require Ash.Query

  alias Samen.Replay.{Capture, Decoder, Frame, Session, Shape}

  @list_limit 50
  @frame_limit 2_000
  @gap_ms 5_000

  @session_fields [
    :id,
    :org_id,
    :view,
    :view_md5,
    :started_at,
    :ended_at,
    :exit_reason,
    :frame_count,
    :interaction_count,
    :rejected_count,
    :truncated
  ]

  @doc """
  The newest sessions the viewer's scope may read (at most #{@list_limit}), as bounded metadata
  maps: `id`, `view` / `view_short` (the module name and its last segment), `view_md5`, timing
  and counters (pass one to `drift/1` for the code-drift marker).
  """
  @spec list(Samen.Scope.t(), keyword()) :: [map()]
  def list(%Samen.Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @list_limit) |> min(@list_limit) |> max(1)

    Session
    |> Ash.Query.select(@session_fields)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, sessions} -> Enum.map(sessions, &meta/1)
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Load one session and its decoded frames under the viewer's scope. `{:ok, %{session, frames}}`
  or `{:error, :not_found}` (absent, another org's, or unreadable — indistinguishable).
  """
  @spec load(Samen.Scope.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def load(%Samen.Scope{} = scope, id) when is_binary(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, [session]} <-
           Session
           |> Ash.Query.select(@session_fields)
           |> Ash.Query.filter(id == ^id)
           |> Ash.read(scope: scope),
         {:ok, frames} <-
           Frame
           |> Ash.Query.filter(session_id == ^session.id)
           |> Ash.Query.sort(seq: :asc)
           |> Ash.Query.limit(@frame_limit)
           |> Ash.read(scope: scope) do
      {:ok, %{session: meta(session), frames: Enum.map(frames, &Decoder.frame/1)}}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def load(_scope, _id), do: {:error, :not_found}

  @doc """
  The assigns frame `index` (0-based into `frames`) showed: the mount frame's assigns with
  every later render frame's changed assigns merged on top, plus `:live_action`. Top-level
  keys that are not atoms (a positional `$kN`) are dropped — a template reads `@name`.
  """
  @spec assigns_at([map()], non_neg_integer()) :: map()
  def assigns_at(frames, index) when is_list(frames) and is_integer(index) do
    frames
    |> Enum.take(index + 1)
    |> Enum.reduce(%{}, fn
      %{kind: :mount, payload: payload}, _acc ->
        payload
        |> Map.get(:assigns, %{})
        |> atom_keys()
        |> Map.put(:live_action, live_action(Map.get(payload, :live_action)))

      %{kind: :render, payload: payload}, acc ->
        Map.merge(acc, payload |> Map.get(:assigns, %{}) |> atom_keys())

      _other, acc ->
        acc
    end)
  end

  defp atom_keys(map) when is_map(map),
    do: map |> Enum.filter(fn {k, _} -> is_atom(k) end) |> Map.new()

  defp atom_keys(_), do: %{}

  defp live_action(v) when is_binary(v), do: Decoder.existing_atom(v)
  defp live_action(_), do: nil

  @doc "Resolve decoded assigns on the viewer's plane (`Samen.Replay.Resolver.resolve/3`)."
  @spec resolve(map(), Samen.Scope.t(), keyword()) :: %{value: map(), refs: list()}
  def resolve(assigns, scope, opts \\ []), do: Samen.Replay.Resolver.resolve(assigns, scope, opts)

  @doc """
  The code-drift marker: `:same` (the loaded view module's MD5 equals the recorded one),
  `:changed` (it differs, or no MD5 was recorded), `:missing` (the module no longer exists or
  is not a LiveView).
  """
  @spec drift(map()) :: :same | :changed | :missing
  def drift(%{view: view, view_md5: md5}) do
    case view_module(view) do
      nil -> :missing
      mod -> if md5 != nil and Capture.md5(mod) == md5, do: :same, else: :changed
    end
  end

  def drift(_), do: :missing

  @doc "The loaded LiveView module a stored view name names, or `nil`."
  @spec view_module(term()) :: module() | nil
  def view_module(name) do
    case Decoder.module(name) do
      nil -> nil
      mod -> if function_exported?(mod, :render, 1), do: mod
    end
  end

  @doc """
  The timeline: one bounded entry per frame (`index`, `seq`, `at_ms`, `kind`, `label`) plus
  `gap` entries where the recording skipped (a missing `seq` — a frame refused at persist — or
  more than #{div(@gap_ms, 1000)}s of idle time).
  """
  @spec timeline([map()]) :: [map()]
  def timeline(frames) do
    {entries, _} =
      frames
      |> Enum.with_index()
      |> Enum.flat_map_reduce(nil, fn {f, i}, prev ->
        gap = gap_entry(prev, f)
        entry = %{type: :frame, index: i, seq: f.seq, at_ms: f.at_ms, kind: f.kind, label: label(f)}
        {List.wrap(gap) ++ [entry], f}
      end)

    entries
  end

  defp gap_entry(nil, _f), do: nil

  defp gap_entry(prev, f) do
    missing = f.seq - prev.seq - 1
    idle = f.at_ms - prev.at_ms

    cond do
      missing > 0 -> %{type: :gap, reason: :missing_frames, n: missing}
      idle > @gap_ms -> %{type: :gap, reason: :idle, n: div(idle, 1000)}
      true -> nil
    end
  end

  @doc "A frame's bounded label (every part was schema-validated at persist and re-checked)."
  @spec label(map()) :: String.t()
  def label(%{kind: :mount, payload: p}), do: "mount #{short(p[:view])}"
  def label(%{kind: :params, payload: p}), do: "navigate #{p[:route] || ""}"
  def label(%{kind: :event, payload: p}), do: "event #{p[:event] || "other"}"

  def label(%{kind: :component_event, payload: p}),
    do: "event #{p[:event] || "other"} (#{short(p[:component])})"

  def label(%{kind: :render, payload: p}), do: "render (#{map_size(Map.get(p, :assigns, %{}))} changed)"
  def label(%{kind: :info, payload: p}), do: "message #{p[:tag] || ""}"
  def label(%{kind: :exit, payload: p}), do: "exit #{p[:reason] || ""}"
  def label(%{kind: :truncated, payload: p}), do: "truncated (#{p[:cap] || "cap"})"
  def label(%{kind: :invalid}), do: "unreadable frame"
  def label(_), do: "frame"

  @doc "The param shape of an event/params frame as display rows (key, type, length, class, value)."
  @spec shape_rows(map()) :: [map()]
  def shape_rows(%{payload: %{params: %Shape{fields: fields}}}), do: fields
  def shape_rows(_), do: []

  @doc """
  Write the ONE token-only `aud_event` row an open produces (ADR-052 §2.3 rule 2), through the
  shared writer (`Samen.AuditChain.Writer.write/2` — its PII-reason scan runs on `detail`), on
  the replay org's chain:

    * `event_type` `"replay.viewed"`, `subject_id` the replay session id,
    * `actor_id` the viewer's id (the operator id, or the tenant principal id),
    * `correlation_id` the impersonation session id (operator plane; `nil` for a tenant admin),
    * `detail` `"event=replay.viewed plane=<operator|tenant>"` — no reason text beyond the
      impersonation session's own.
  """
  @spec audit_viewed(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit_viewed(viewer, opts \\ [])

  def audit_viewed(%{replay_id: replay_id, org_id: org_id, viewer_id: viewer_id, plane: plane} = v, opts)
      when plane in [:operator, :tenant] and is_binary(replay_id) and is_binary(org_id) do
    repo = Keyword.get_lazy(opts, :repo, fn -> AshPostgres.DataLayer.Info.repo(Session, :mutate) end)

    Samen.AuditChain.Writer.write(repo, %{
      org_id: org_id,
      event_type: "replay.viewed",
      subject_id: replay_id,
      actor_id: viewer_id && to_string(viewer_id),
      correlation_id: Map.get(v, :impersonation_session_id),
      detail: "event=replay.viewed plane=#{plane}",
      occurred_at: DateTime.utc_now()
    })
  rescue
    e -> {:error, {:audit_raised, e.__struct__}}
  end

  def audit_viewed(_viewer, _opts), do: {:error, :invalid_viewer}

  defp meta(%Session{} = s) do
    %{
      id: s.id,
      org_id: s.org_id && to_string(s.org_id),
      view: s.view,
      view_short: short(s.view),
      view_md5: s.view_md5,
      started_at: s.started_at,
      ended_at: s.ended_at,
      exit_reason: s.exit_reason,
      frame_count: s.frame_count,
      interaction_count: s.interaction_count,
      rejected_count: s.rejected_count,
      truncated: s.truncated
    }
  end

  defp short(name) when is_binary(name), do: name |> String.split(".") |> List.last()
  defp short(_), do: ""
end
