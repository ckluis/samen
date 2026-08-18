defmodule Samen.Files.ChokepointGuard do
  @moduledoc """
  The **no-ungoverned-file-row** guard (ADR-026 §2 decision 2, RP-FI-1 · AC-G14-2) —
  an `Ash.Resource.Change` on the `File` resource create AND update paths that REFUSES a
  write which sets/repoints a `storage_key` UNLESS the changeset came through
  `Samen.Files.upload/3`.

  ## The hole this closes

  ADR-026 ratifies that `Samen.Files.upload/3` is the ONLY path that may mint a
  `storage_key`-bearing `File` row (line 22: "no ungoverned file row true by
  construction"; line 33: "a structural fact, not a convention a host must remember").
  Without this guard that guarantee was convention-only: the `File` resource exposes a
  public default `:create` action (`create: :*`) AND a public default `:update` action
  (`update: :*`), both of which accept `storage_key` (`public?: true`). So either a direct
  `Ash.create` OR a direct `Ash.update` (a hand-crafted write, an API path, a fixture)
  could attach/repoint a `storage_key` on a row while SKIPPING size/type enforcement
  (RP-FI-5), the org-scoped chokepoint, and the `file.uploaded`/promoted audit write — an
  ungoverned file row. A create-only guard left an **update-shaped hole**: a member+ actor
  could create a governed row, then `Ash.update` it to repoint `storage_key` at an
  arbitrary/unscanned/oversize key with no marker, no enforcement, and no audit. This
  change closes BOTH shapes so the guarantee is STRUCTURAL on every write: the size/type +
  audit governance cannot be bypassed by writing a `storage_key` on a create OR an update.

  ## The `:destroy` action type (T37h — ADR-040 §5.9 footnote §, the E6 archive/restore
  ## sanction)

  The File resource is `archivable: true` (T37e). Its E6 substrate adds `:archive` and
  `:destroy_permanently` (`destroy`-typed) and `:restore` (`update`-typed). Registering
  this change `on: [:create, :update]` only meant a `destroy`-typed action NEVER even
  reached this guard — not because archive/restore were sanctioned, but because the
  action-type filter excluded them entirely, a **destroy-shaped twin** of the update-
  shaped hole above (the same class of gap: "a write mode this guard doesn't watch").
  Registering `on: [:create, :update, :destroy]` closes it: every `destroy`-typed action
  (the soft `:destroy`, `:archive`, `:destroy_permanently`) now runs through
  `refuse_ungoverned_storage_key/1` too. None of them touch `storage_key`
  (`:archive`/`:destroy` only set `archived_at`; `:destroy_permanently` sets nothing —
  it deletes the row), so `sets_storage_key?/1` is `false` for all of them and they pass
  unconditionally — archive/restore are now STRUCTURALLY sanctioned (evaluated and
  allowed by the same guard, not exempt from it), and a hypothetical future `destroy`-
  typed action that DID try to smuggle a `storage_key` change is refused by construction,
  not by nobody having written one yet.

  ## The rule — refuse a storage_key write that did not come through the chokepoint

  `Samen.Files.upload/3` stamps the changeset context with the private marker
  `%{private: %{samen_files_chokepoint: true}}` (via `Ash.Changeset.set_context/2`) right
  before it calls the governed create. This change fires as a `before_action` on both the
  create and the update and:

    * ALLOWS the write when the chokepoint marker is present (the governed path).
    * ALLOWS a write that does NOT set/change `storage_key` (a `storage_key`-less draft
      row, or an update that touches only other attributes, carries no ungoverned pointer —
      nothing to govern; the chokepoint is the only thing that ever attaches a real key).
    * REFUSES a create OR update that sets a non-nil `storage_key` WITHOUT the chokepoint
      marker — the direct-`Ash.create` bypass RP-FI-1 forbids AND the direct-`Ash.update`
      repoint that is its update-shaped twin. The write is aborted inside the action's
      transaction (the DB is provably unchanged).

  The marker lives under `context.private` — a namespace a host/API caller does not set on
  an ordinary create — so a bypass caller cannot forge it by passing ordinary attributes,
  and the private context is not exposed as a public action argument.

  ## Anti-tautology / sabotage

  Sabotaging the chokepoint (removing the `set_context` stamp, or widening this guard to
  allow any `storage_key` write) FLIPS the RP-FI-1 red-path tests: a direct `Ash.create`
  of a `storage_key`-bearing row — OR a direct `Ash.update` repointing `storage_key` — would
  then SUCCEED, and the tests that assert each is `{:error, _}` (refused) would fail.
  Narrowing the registration back to `on: [:create]` (dropping `:update`) re-opens the
  update-shaped hole and FLIPS the update red-path. Narrowing it back to
  `on: [:create, :update]` (dropping `:destroy`, T37h's addition) re-opens the destroy-
  shaped hole and FLIPS `test/files_upload_test.exs`'s "archive/restore sanction" red
  test (a raw `:destroy`-typed changeset force-changing `storage_key` would then slip
  through unrefused). Mirrors `Samen.Pii.WriteGuard`'s before-action rejection pattern.
  """
  use Ash.Resource.Change

  @marker_key :samen_files_chokepoint

  @doc false
  def marker_key, do: @marker_key

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_ungoverned_storage_key/1)
  end

  # T37h: with the registration widened to `on: [:create, :update, :destroy]`, this
  # change now also attaches to `:destroy_permanently` (same action TYPE as `:archive`/
  # the soft `:destroy`), which — unlike `:archive` (forced `require_atomic?: false` by
  # the archival DSL) — is otherwise atomic-eligible. Without this callback,
  # `:destroy_permanently` would spuriously lose atomic eligibility just for sharing a
  # type with a non-atomic change (`mix compile --warnings-as-errors` catches this).
  # `:ok` tells Ash's atomicity checker this change contributes nothing when running
  # atomically; the normal (non-bulk) `Ash.destroy/2` path this guard actually governs
  # still runs `change/3`'s `before_action` hook regardless — mirrors
  # `Samen.Scopes.Support.CascadeArchive.atomic/3`'s identical precedent.
  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  defp refuse_ungoverned_storage_key(changeset) do
    cond do
      chokepoint?(changeset) ->
        # Came through Samen.Files.upload/3 — governed. Allow.
        changeset

      not sets_storage_key?(changeset) ->
        # No storage_key attached — no ungoverned pointer to govern. Allow.
        changeset

      true ->
        # A direct create OR update setting/repointing a storage_key WITHOUT passing the
        # chokepoint: the exact bypass RP-FI-1 forbids (and its update-shaped twin). Refuse —
        # aborts inside the action transaction, DB unchanged.
        Ash.Changeset.add_error(
          changeset,
          field: :storage_key,
          message:
            "ungoverned-file-row (ADR-026 RP-FI-1 / AC-G14-2): a File row's storage_key can " <>
              "only be set/repointed through Samen.Files.upload/3 (which enforces size/type " <>
              "limits and writes the file.uploaded audit). A direct Ash.create or Ash.update " <>
              "setting a storage_key bypasses that governance and is refused — the DB is " <>
              "unchanged. Route the upload through Samen.Files.upload/3."
        )
    end
  end

  # The chokepoint marker is set by Samen.Files.upload/3 under context.private so a host/
  # API caller cannot forge it via ordinary attributes.
  defp chokepoint?(changeset) do
    get_in(changeset.context, [:private, @marker_key]) == true
  end

  # A "storage_key write" is a changeset that SETS/REPOINTS storage_key to a non-nil value —
  # the ungoverned pointer. On an update, `fetch_change/2` returns `{:ok, value}` ONLY when
  # the attribute actually changes, so an update that touches other attributes (leaving
  # storage_key untouched) is `:error` here and passes freely; only an actual repoint is
  # gated. An untouched storage_key, or an explicit nil, is not a mint.
  defp sets_storage_key?(changeset) do
    case Ash.Changeset.fetch_change(changeset, :storage_key) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end
end
