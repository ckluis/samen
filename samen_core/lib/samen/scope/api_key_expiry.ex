defmodule Samen.Scope.ApiKey.ClampExpiry do
  @moduledoc """
  Resource change: every write that sets a key's `expires_at` enforces the F3.4 ceiling
  (`Samen.Scope.ApiKey.max_ttl_seconds/0`) ON THE RESOURCE, so it holds for EVERY write
  path (the settings mint, the default create/update, a host's own call), not just
  `Samen.Web.Settings.ApiKeys.mint/3`.

    * a missing (`nil`) expiry becomes `now + default_ttl` — a key is never unbounded,
      on create or when an update clears it;
    * a time beyond `now + max_ttl` clamps down to it;
    * a time at/before `now` is KEPT: it only ever shortens a key's life (an already-dead
      key authorizes nothing, and an update that sets a past expiry is how a key is
      retired early). `bounded_expiry/2` would turn it into `now + default_ttl` and so
      EXTEND the key — the opposite of what a past expiry asks for.

  Applies on CREATE always, and on UPDATE only when the changeset changes `expires_at`.
  """
  use Ash.Resource.Change

  alias Samen.Scope.ApiKey

  @impl true
  def change(changeset, _opts, _ctx) do
    if changeset.action.type == :create or Ash.Changeset.changing_attribute?(changeset, :expires_at) do
      now = DateTime.utc_now()

      clamped =
        case Ash.Changeset.get_attribute(changeset, :expires_at) do
          nil -> ApiKey.bounded_expiry(nil, now)
          %DateTime{} = requested -> min_datetime(requested, DateTime.add(now, ApiKey.max_ttl_seconds(), :second))
        end
        |> DateTime.truncate(:second)

      Ash.Changeset.force_change_attribute(changeset, :expires_at, clamped)
    else
      changeset
    end
  end

  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
