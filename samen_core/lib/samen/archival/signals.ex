defmodule Samen.Archival.Signals do
  @moduledoc """
  The two archival signals an archivable resource emits (issue #96 D3), declared by
  `use Samen.Archival.Signals` in a module of the resource's own:

    * `:archived` — after `:archive`, with `record_id` and the `archived_at` instant just
      stamped (or, on a re-archive, the preserved original instant — `Samen.Archival.Archive`);
    * `:restored` — after `:restore`, with `record_id` and the PRE-restore `archived_at`
      (`nil` when the record was already live, a no-op restore).

  A resource emits them with `use Samen.Resource, archivable: true, archival_signals: <the
  module>`, which adds the `emit`s to the generated `:archive`/`:restore` actions. A
  composition cascade (ADR-040 §5.4) is then a listener on the CHILD resource
  (`signals_in`), so the parent no longer names its children: the scopes' cascades
  (`Samen.Scopes.{Cms,Support,Work}.Cascade*`, `Samen.Scopes.Chat.Cascade*`) are those
  listeners.

  Listeners run inline (`Ash.Signals.Delivery.Inline`), inside the parent's transaction, so a
  failing cascade rolls the parent's archive/restore back. Both fields are non-PII (a uuid and
  a timestamp), which `mix samen.verify.signals_no_pii` checks.

  ## One module per emitting resource

  Ash finds a signal's listeners across the whole code path, and the `:ash_signals` compiler
  consolidates them into the build path of the app being compiled. A scope mounted twice in
  one app (the tenant Support scope and the operator ticket desk) or by several apps
  therefore declares a module per mount, next to the resource (`<Resource>.Archival`), never
  one shared module: a shared one would deliver one mount's archive to every mount's
  listeners, and a host's listeners would be missing from a dispatch consolidated in
  samen_core.
  """

  defmacro __using__(_opts) do
    quote do
      use Ash.Signals

      signals do
        signal :archived do
          argument(:record_id, :uuid, allow_nil?: false)
          argument(:archived_at, :utc_datetime_usec, allow_nil?: false)
        end

        signal :restored do
          argument(:record_id, :uuid, allow_nil?: false)
          # `nil` for a no-op restore of a live record: there is nothing to cascade.
          argument(:archived_at, :utc_datetime_usec)
        end
      end
    end
  end
end
