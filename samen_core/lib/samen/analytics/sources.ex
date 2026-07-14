defmodule Samen.Analytics.Sources do
  @moduledoc """
  The **framework event sources** for the product-analytics seed set (WS-B / G12;
  design §4.2). One best-effort emit function per seed event, each building a bounded,
  catalog-valid, token-blind payload and handing it to `Samen.Analytics.track/1`.

  These are the choke-point helpers the framework calls so VERTICALS inherit emission
  at 0 LOC — a vertical never authors an event; it calls (or the framework calls on
  its behalf) `session_signed_in/2`, `first_run_completed/1`, `record_created/3`,
  `search_used/3`. The `flag.assignment` source is the config-wired
  `{Samen.Analytics, :track}` emitter on `Samen.FeatureFlags` (design §3.4) — no
  function here; every variant assignment already flows to `track/1`.

  ## Best-effort by contract

  Every function returns whatever `track/1` returns and NEVER raises — a capture
  failure never aborts the action that fired it (the A4 emit posture, exactly like
  `Samen.Notifications.Engine.emit/2` and the `mov` `SubscriptionMovement` change).

  ## Token-blind payloads by construction

  Each source passes only bounded, non-PII values: an org id, a subject id (which
  `track/1` pseudonymizes to `pae_actor_ref` — never stored raw), a bounded entity
  ref, and catalog-registered prop KEYS carrying bounded LABEL values (a resource
  name atom, a surface atom, a count). No source ever forwards a name/email/freeform
  string — and if a caller tried, `track/1`'s capture-time PII refusal drops it.
  """

  alias Samen.Analytics

  @doc """
  `session.signed_in` — a subject established a session for `org_id`. The framework
  session choke point (the current-org write) calls this; verticals inherit it.

  `subject_id` is optional and is pseudonymized to `pae_actor_ref` by `track/1`
  (never stored raw). Best-effort.
  """
  @spec session_signed_in(String.t(), String.t() | nil) ::
          {:ok, struct()} | {:ok, :dropped} | {:error, term()}
  def session_signed_in(org_id, subject_id \\ nil) do
    Analytics.track(%{
      org_id: org_id,
      event_name: "session.signed_in",
      subject_id: subject_id
    })
  end

  @doc """
  `first_run.completed` — `org_id` finished first-run onboarding (its first core row
  exists, so the first-run checklist retires). The framework first-run surface calls
  this on the empty→non-empty transition. Best-effort.
  """
  @spec first_run_completed(String.t()) ::
          {:ok, struct()} | {:ok, :dropped} | {:error, term()}
  def first_run_completed(org_id) do
    Analytics.track(%{
      org_id: org_id,
      event_name: "first_run.completed"
    })
  end

  @doc """
  `record.created` — a governed resource row was created in `org_id`. The framework
  kit create path calls this; verticals inherit it. `resource` is the bounded
  resource identifier (a module or a short name — coerced to a bounded label), and
  `entity_ref` is the new row's opaque id. `subject_id` (optional) pseudonymizes to
  `pae_actor_ref`. Best-effort.
  """
  @spec record_created(String.t(), module() | atom() | String.t(), keyword()) ::
          {:ok, struct()} | {:ok, :dropped} | {:error, term()}
  def record_created(org_id, resource, opts \\ []) do
    Analytics.track(%{
      org_id: org_id,
      event_name: "record.created",
      subject_id: Keyword.get(opts, :subject_id),
      entity_ref: Keyword.get(opts, :entity_ref),
      props: %{"resource" => resource_label(resource)}
    })
  end

  @doc """
  `search.used` — a search query ran in `org_id`. The framework search choke point
  calls this. `surface` is a bounded surface atom (e.g. `:crm`, `:support`), and
  `result_count` an integer. NO query TEXT is ever passed (it would be a freeform
  string — `track/1` would refuse it, and this source never forwards it). Best-effort.
  """
  @spec search_used(String.t(), atom() | String.t(), keyword()) ::
          {:ok, struct()} | {:ok, :dropped} | {:error, term()}
  def search_used(org_id, surface, opts \\ []) do
    props =
      %{"surface" => surface_label(surface)}
      |> maybe_put("result_count", Keyword.get(opts, :result_count))

    Analytics.track(%{
      org_id: org_id,
      event_name: "search.used",
      subject_id: Keyword.get(opts, :subject_id),
      props: props
    })
  end

  # A bounded, low-cardinality resource label atom. A module name is reduced to its
  # LAST segment (a bounded label, not a full module path), lowercased. This keeps
  # the prop a bounded enum-ish label, never a freeform string.
  defp resource_label(mod) when is_atom(mod) and not is_nil(mod) do
    mod
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  rescue
    # A bare (non-module) atom passes through unchanged.
    _ -> mod
  end

  defp resource_label(other) when is_binary(other), do: other |> String.downcase() |> safe_atom()
  defp resource_label(other), do: other

  defp surface_label(s) when is_atom(s), do: s
  defp surface_label(s) when is_binary(s), do: safe_atom(s)
  defp surface_label(s), do: s

  # Reuse an existing atom when possible; a novel bounded label becomes a new atom.
  # Both are bounded LABELS (surface/resource names), never subject data.
  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
