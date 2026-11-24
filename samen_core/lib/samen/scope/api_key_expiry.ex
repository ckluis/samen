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

    * the new value is `min(requested, clamp ceiling, STORED expires_at)`, computed in the UPDATE statement
      from the stored row (not from the struct in hand); a later time than the stored one is ignored (the
      stored value is kept), never an extension;
    * `nil` keeps the current value (it used to become `now + default_ttl`, which
      extended any key and revived expired ones);
    * a row whose current `expires_at` is `nil` (a legacy, pre-gate row) may be given an
      expiry (clamped to the ceiling) — the only direction open to it;
    * an update to an already-EXPIRED or REVOKED row is refused outright: the statement carries the filter
      `revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now)`, so a stale struct of a key retired
      since matches zero rows and the update fails; no action can turn a dead key back into a live one (a new
      key is minted under the role ceiling).

  An update that does not touch `expires_at` is left alone.
  """
  use Ash.Resource.Change

  alias Samen.Scope.ApiKey

  require Ash.Expr

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

  # The DATABASE decides on update: whether the key is still live and which expiry is earlier are both
  # evaluated against the STORED row, never against the struct the caller holds (a stale struct used to let an
  # actor write a later expiry over a key another actor had just retired, reviving it).
  #   * the update only applies to a row that is still live: `revoked_at IS NULL AND (expires_at IS NULL OR
  #     expires_at > now)`. A stale struct of a key retired or revoked since matches zero rows and the
  #     update fails (`Ash.Error.Changes.StaleRecord`); it never writes.
  #   * the written expiry is `least(stored expires_at, min(requested, ceiling))` in the statement; a stored
  #     `NULL` (a legacy row) takes the clamped request; a `nil` request keeps the stored value.
  defp update(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :expires_at) do
      now = DateTime.utc_now()
      requested = Ash.Changeset.get_attribute(changeset, :expires_at)

      changeset
      |> Ash.Changeset.clear_change(:expires_at)
      |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(revoked_at) and (is_nil(expires_at) or expires_at > ^now)))
      |> Ash.Changeset.atomic_update(:expires_at, shortened(requested, now))
    else
      changeset
    end
  end

  # nil keeps the stored value; otherwise the earlier of the stored value and the clamped request.
  defp shortened(nil, _now), do: Ash.Expr.expr(expires_at)

  defp shortened(%DateTime{} = requested, now) do
    bounded = requested |> min_datetime(ceiling(now)) |> DateTime.truncate(:second)
    Ash.Expr.expr(if(is_nil(expires_at), do: ^bounded, else: if(expires_at > ^bounded, do: ^bounded, else: expires_at)))
  end

  defp ceiling(now), do: DateTime.add(now, ApiKey.max_ttl_seconds(), :second)

  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
