defmodule Samen.Automation.Actions.Support do
  @moduledoc """
  Shared helpers for the E2 action library (ADR-039 §5.2): resource resolution,
  governed subject fetch/write, `{{subject.attr}}` interpolation, and
  recipient-selector resolution (`"owner" | "org" | <literal id>` — the
  convention T39's `Notify` established). Every `Samen.Automation.Actions.*`
  module builds on these instead of re-deriving them (leverage guard, house
  CLAUDE.md "framework-first").

  ## Interpolation is a projection, not a second gate (INV-1)

  `interpolate/2` substitutes `{{subject.<attr>}}` against `ctx.subject` — the
  `Samen.Automation.RunWorker` eligible-only projection (ADR-039 §4.4 read-side
  twin). A vaulted/plaintext-PII attribute reference is refused at WRITE time by
  `Samen.Automation.NonPiiPredicates` (it can never be STORED in a config), and
  even if one somehow reached fire time, `ctx.subject` structurally does not
  carry the value — the substitution silently yields `""`, never a crash, never
  a leak. This module never needs to know about masking; the boundary upstream
  guarantees it (the same posture `Samen.Automation.Condition`'s moduledoc
  documents for the evaluator).

  ## Governed writes only (INV-2 / T40 c3)

  `governed_update/3` and `governed_create/3` ALWAYS pass `actor: ctx.actor` (the
  run's OWNER, re-resolved by `RunWorker` — ADR-039 §4.5) — never
  `authorize?: false`. A policy that refuses the owner's write surfaces as
  `{:error, :unauthorized}`, exactly like any other actor-authorized Ash call —
  no system-actor bypass exists anywhere in the action library.
  """

  alias Samen.Automation.Context

  @interp_rx ~r/\{\{\s*subject\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/

  @doc "Resolve a catalog `resource_key` (fully-qualified module string) to its Ash resource module."
  @spec resolve_resource(String.t() | nil) :: {:ok, module()} | :error
  def resolve_resource(str) when is_binary(str) and str != "" do
    mod = String.to_existing_atom("Elixir." <> String.trim_leading(str, "Elixir."))
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: :error
  rescue
    ArgumentError -> :error
  end

  def resolve_resource(_), do: :error

  @doc """
  Governed fetch of the fire-time SUBJECT record (`ctx.resource_key` /
  `ctx.record_id`), authorized as `ctx.actor`. `{:error, :no_subject_record}` for
  a schedule/manual trigger that carried no chosen record — an honest, isolated
  failure (ADR-039 §5.1 "action failures never crash the engine"), never a raise.
  """
  @spec fetch_subject(Context.t()) :: {:ok, struct()} | {:error, atom()}
  def fetch_subject(%Context{resource_key: rk, record_id: rid, actor: actor})
      when is_binary(rk) and is_binary(rid) and rk != "" and rid != "" do
    with {:ok, resource} <- resolve_resource(rk) do
      case Ash.get(resource, rid, actor: actor) do
        {:ok, record} -> {:ok, record}
        {:error, error} -> if forbidden_error?(error), do: {:error, :unauthorized}, else: {:error, :not_found}
      end
    else
      :error -> {:error, :unknown_resource}
    end
  end

  def fetch_subject(_ctx), do: {:error, :no_subject_record}

  @doc "Governed update of `record` with `attrs`, authorized as `ctx.actor` (T40 c3 — no bypass)."
  @spec governed_update(struct(), map(), Context.t()) :: {:ok, struct()} | {:error, atom()}
  def governed_update(record, attrs, %Context{actor: actor}) do
    record
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update()
    |> normalize_write_error()
  end

  @doc "Governed create of `resource` with `attrs`, authorized as `ctx.actor`."
  @spec governed_create(module(), map(), Context.t()) :: {:ok, struct()} | {:error, atom()}
  def governed_create(resource, attrs, %Context{actor: actor}) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
    |> normalize_write_error()
  end

  defp normalize_write_error({:ok, record}), do: {:ok, record}

  defp normalize_write_error({:error, error}) do
    if forbidden_error?(error), do: {:error, :unauthorized}, else: {:error, :write_failed}
  end

  # Ash policy denials surface as `%Ash.Error.Forbidden{}` directly, OR wrapped
  # inside `%Ash.Error.Invalid{errors: [...]}` — check both shapes, plus the
  # generic `:class` field every Ash.Error carries, rather than guessing one
  # exact struct shape (defense against an Ash version renaming the wrapper).
  defp forbidden_error?(%Ash.Error.Forbidden{}), do: true

  defp forbidden_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &forbidden_error?/1)

  defp forbidden_error?(error) do
    case Map.get(error, :class) do
      :forbidden -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Substitute every `{{subject.<attr>}}` in `value` against `ctx.subject`
  (recursively through maps/lists; non-string leaves pass through unchanged). A
  referenced attribute absent from `ctx.subject` substitutes `""` — never
  raises, never reaches for a raw record.
  """
  @spec interpolate(term(), Context.t()) :: term()
  def interpolate(value, %Context{} = ctx) when is_binary(value) do
    Regex.replace(@interp_rx, value, fn _whole, attr -> subject_value(ctx.subject, attr) end)
  end

  def interpolate(value, %Context{} = ctx) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, interpolate(v, ctx)} end)
  end

  def interpolate(value, %Context{} = ctx) when is_list(value),
    do: Enum.map(value, &interpolate(&1, ctx))

  def interpolate(value, %Context{}), do: value

  defp subject_value(subject, attr) do
    subject = subject || %{}
    key = safe_atom(attr)

    value =
      cond do
        not is_nil(key) and Map.has_key?(subject, key) -> Map.get(subject, key)
        Map.has_key?(subject, attr) -> Map.get(subject, attr)
        true -> nil
      end

    if is_nil(value), do: "", else: to_string(value)
  end

  @doc "\"owner\" -> the run owner's id; \"org\" -> the org id; else treated as a literal id."
  @spec resolve_recipient(String.t() | nil, Context.t()) :: String.t() | nil
  def resolve_recipient("owner", ctx), do: actor_id(ctx.actor)
  def resolve_recipient("org", ctx), do: ctx.org_id
  def resolve_recipient(user_id, _ctx) when is_binary(user_id) and user_id != "", do: user_id
  def resolve_recipient(_, ctx), do: actor_id(ctx.actor)

  @doc "Extract a bounded id from the run's owner-actor (a `Samen.Scope` struct, a map, or a bare id)."
  @spec actor_id(term()) :: String.t() | nil
  def actor_id(%{actor: %{id: id}}), do: id
  def actor_id(%{id: id}), do: id
  def actor_id(id) when is_binary(id), do: id
  def actor_id(_), do: nil

  @doc "A safe `String.to_existing_atom/1` — `nil` (never a raise) on an unknown atom."
  @spec safe_atom(String.t()) :: atom() | nil
  def safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  def safe_atom(_), do: nil
end
