defmodule Samen.Scope.ApiKey.ClampExpiry do
  @moduledoc """
  Resource change: every write that sets a key's `expires_at` enforces the F3.4 ceiling
  (`Samen.Scope.ApiKey.max_ttl_seconds/0`) ON THE RESOURCE, so it holds for EVERY write
  path (the settings mint, the default create/update, a host's own call), not just
  `Samen.Web.Settings.ApiKeys.mint/3`.

  ## On CREATE

    * a missing (`nil`) expiry becomes `now + default_ttl` — a key is never unbounded;
    * a time beyond `now + max_ttl` clamps down to it;
    * a time at/before `now` is KEPT (a born-dead key authorizes nothing).

  ## On UPDATE — an update may only SHORTEN a key's life

    * the new value is `min(requested, clamp ceiling, current expires_at)`; a later time
      than the current one is ignored (the current value is kept), never an extension;
    * `nil` keeps the current value (it used to become `now + default_ttl`, which
      extended any key and revived expired ones);
    * a row whose current `expires_at` is `nil` (a legacy, pre-gate row) may be given an
      expiry (clamped to the ceiling) — the only direction open to it;
    * an update to an already-EXPIRED or REVOKED row is refused outright: no action can
      turn a dead key back into a live one (a new key is minted under the role ceiling).

  An update that does not touch `expires_at` is left alone.
  """
  use Ash.Resource.Change

  alias Samen.Scope.ApiKey

  @impl true
  def change(changeset, _opts, _ctx) do
    if changeset.action.type == :create do
      now = DateTime.utc_now()

      clamped =
        case Ash.Changeset.get_attribute(changeset, :expires_at) do
          nil -> ApiKey.bounded_expiry(nil, now)
          %DateTime{} = requested -> min_datetime(requested, ceiling(now))
        end
        |> DateTime.truncate(:second)

      Ash.Changeset.force_change_attribute(changeset, :expires_at, clamped)
    else
      update(changeset)
    end
  end

  defp update(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :expires_at) do
      now = DateTime.utc_now()
      data = changeset.data

      cond do
        revoked?(data) ->
          Ash.Changeset.add_error(changeset, field: :expires_at, message: "a revoked key cannot be changed")

        match?(%Ash.NotLoaded{}, Map.get(data, :expires_at)) ->
          Ash.Changeset.add_error(changeset, field: :expires_at, message: "the key's current expiry was not loaded")

        ApiKey.expired?(data, now) ->
          Ash.Changeset.add_error(changeset, field: :expires_at, message: "an expired key cannot be changed")

        true ->
          current = Map.get(data, :expires_at)
          requested = Ash.Changeset.get_attribute(changeset, :expires_at)
          Ash.Changeset.force_change_attribute(changeset, :expires_at, shorten(requested, current, now))
      end
    else
      changeset
    end
  end

  # nil keeps the current value; a legacy nil current takes the (clamped) request.
  defp shorten(nil, current, _now), do: current

  defp shorten(%DateTime{} = requested, current, now) do
    bounded = min_datetime(requested, ceiling(now))

    case current do
      %DateTime{} -> min_datetime(bounded, current)
      _ -> bounded
    end
    |> DateTime.truncate(:second)
  end

  # Fail closed: a row read without `revoked_at` loaded (NotLoaded) is not trusted as live.
  defp revoked?(data), do: not match?(%{revoked_at: nil}, data)

  defp ceiling(now), do: DateTime.add(now, ApiKey.max_ttl_seconds(), :second)

  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
