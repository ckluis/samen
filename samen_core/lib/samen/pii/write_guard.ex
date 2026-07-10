defmodule Samen.Pii.WriteGuard do
  @moduledoc """
  The **no-operator-plaintext-write** guard (WS-A design §1.2 MC-1, ADR-016 Invariant L1)
  — a global `Ash.Resource.Change` that REFUSES a create/update which sets a vault-routed
  `pii_attribute` when the acting actor is on the **operator plane**.

  ## The hole this closes

  A2 proved masking on the READ path: an operator impersonating a tenant sees PII as
  `%Masked{}` (`••••`). A3 opens WRITE forms — a NEW PII surface. Without this guard, an
  operator-plane actor (impersonation session) could POST a changeset that OVERWRITES a
  vaulted attribute (`full_name`, `emails`, …) with operator-authored plaintext, which
  `Samen.Vault.Change` would then dutifully encrypt and store: the operator would have
  written into the tenant's PII vault. The masking seam is one-directional (read) unless
  the write path is ALSO closed.

  ## Where it is enforced — the WRITE PATH, not the LiveView

  This is a `before_action` on the framework create/update, injected into EVERY resource
  that has a `pii do` block (by `Samen.Transformers.MaterializePii`, right beside
  `Samen.Vault.Change`). Enforcing it here — not in a LiveView `disabled` attribute —
  means the guard holds for ANY caller on the operator plane: a hand-crafted POST, an API
  path, a future generator-scaffolded form. The LiveView `••••`/disabled input (A2
  `form_field`) is the UX; THIS is the enforcement.

  It runs BEFORE `Samen.Vault.Change`'s own `before_action` in changeset order (this
  change is injected first), so a rejected operator write never reaches the vault store —
  the DB is unchanged (RP-L1: "change rejected, DB unchanged").

  ## The rule — reject on the OPERATOR plane only

  A vaulted-attribute change is refused when `plane == :operator` (the actor map's
  `:plane` key, the SAME key `Samen.Api.PiiResolution` reads). It is ALLOWED when:

    * `plane == :tenant` — the tenant writes its OWN PII in the clear (MC-2 routes it
      through the vault write path); this is the legitimate create/edit surface.
    * `plane` is absent (`nil`) — internal / system writes: SEED data, the vault runtime,
      migrations, `authorize?: false` fixtures. These carry no plane and are not an
      operator; over-refusing them would break seeding and every fixture. (A nil-plane
      actor is NOT an operator by construction — the operator plane is set explicitly by
      `Samen.Web.Plane.scope/2`.)

  This mirrors `Samen.Api.PiiResolution`, which masks specifically on `plane: :operator`
  and leaves a nil-plane internal scope in the clear — the write guard is the write-path
  dual of that read-path rule.

  ## What counts as "setting a vaulted attribute"

  Only a change that provides a NON-TOKEN, NON-`%Masked{}`, NON-nil value for a
  vault-routed field is a plaintext write. A changeset carrying the field's existing
  `%Masked{}`/`vt_*` token (an operator editing a NON-PII field on the same row, with the
  masked value round-tripping untouched) is NOT a plaintext overwrite and is allowed —
  otherwise every operator-plane update to a benign field on a PII-bearing row would be
  blocked. This matches `Samen.Vault.Change`'s own "already vaulted, leave it" rule, so
  the guard fires on exactly the set the vault would otherwise encrypt.
  """
  use Ash.Resource.Change

  alias Samen.Masked
  alias Samen.Pii.Info

  @impl true
  def change(changeset, _opts, context) do
    fields = Info.fields(changeset.resource)

    if fields == [] do
      changeset
    else
      actor = actor_of(context, changeset)

      # Capture the offending fields NOW, at registration time — the changeset still holds
      # the caller's RAW plaintext values. We must not wait until the before_action, because
      # `Samen.Vault.Change`'s own before_action may run first and replace the plaintext with
      # a `%Masked{}` token, hiding the very write we exist to refuse. The rejection itself
      # is still deferred to before_action (so it aborts the transaction), but the DECISION
      # is made on the pre-vault plaintext.
      if operator_plane?(actor) do
        offending =
          fields
          |> Enum.filter(fn field -> plaintext_write?(changeset, field.name) end)
          |> Enum.map(& &1.name)

        # Defer the actual rejection to a before_action so it aborts inside the action's
        # Ecto transaction (the DB is provably unchanged), but evaluate on the offending
        # set captured HERE, from the pre-vault plaintext.
        Ash.Changeset.before_action(changeset, fn cs ->
          reject_operator_plaintext(cs, offending)
        end)
      else
        changeset
      end
    end
  end

  # Reject the write if any vaulted pii_attribute was set to operator-authored plaintext.
  defp reject_operator_plaintext(changeset, offending) do
    case offending do
      [] ->
        changeset

      names ->
        Ash.Changeset.add_error(
          changeset,
          field: hd(names),
          message:
            "no-operator-plaintext-write (MC-1 / Invariant L1): an operator-plane actor " <>
              "cannot write vaulted PII #{inspect(names)}. The operator sees these fields " <>
              "masked (••••) and MUST NOT overwrite them with plaintext — this write is " <>
              "refused at the Ash write path, the DB is unchanged."
        )
    end
  end

  # A field is a "plaintext write" iff the changeset SETS it to a non-token, non-masked,
  # non-nil value — the exact set Samen.Vault.Change would encrypt. An untouched field, an
  # explicit nil (clear), a round-tripping %Masked{}, or a raw vt_* token are NOT writes.
  defp plaintext_write?(changeset, name) do
    case Ash.Changeset.fetch_change(changeset, name) do
      {:ok, %Masked{}} -> false
      {:ok, "vt_" <> _} -> false
      {:ok, nil} -> false
      {:ok, _plaintext} -> true
      :error -> false
    end
  end

  # The actor is captured at change-REGISTRATION time (during `for_action`), when the
  # actor is present at `changeset.context.private.actor` (Ash stores it there via
  # `set_actor/2`). The `context.actor` arg is also honored when populated. We read only
  # the bounded `:plane` marker off the actor map — never PII. Capturing here (not inside
  # the before_action) is deliberate: a nested/sub-action can rebuild `context.private`
  # and drop the actor by the time before_action hooks run, but the registration-time
  # changeset still carries the caller's actor.
  defp actor_of(%{actor: actor}, _changeset) when is_map(actor), do: actor

  defp actor_of(_context, changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      actor when is_map(actor) -> actor
      _ -> nil
    end
  end

  defp operator_plane?(actor) when is_map(actor), do: Map.get(actor, :plane) == :operator
  defp operator_plane?(_), do: false
end
