defmodule Samen.Replay.RowGuard do
  @moduledoc """
  The LAST LINE for the replay tables (ADR-052 §2.2.1, gate fix): a validation on the
  `:record` create action of `Samen.Replay.Frame` and `Samen.Replay.Session`, so EVERY write —
  `Samen.Replay.Store`, or any other code calling `Ash.create`/`Ash.bulk_create` with
  `authorize?: false` (which skips the `forbid_if always()` policy) — passes the same checks.

    * a **frame** must validate against `Samen.Replay.FrameSchema` (`validate/1`): no bare string
      anywhere in its tree, every field of its declared bounded type;
    * a **session**'s three strings must be what the kernel writes: `view` a module name
      (`FrameSchema.module_name?/1`), `view_md5` 32 lowercase hex characters, `actor_ref` the
      P1 HMAC pseudonym (64 lowercase hex characters) — never a principal id, a name or an email.

  The error names the field, never the offending value (an error can be logged).
  """
  use Ash.Resource.Validation

  @hex32 ~r/\A[0-9a-f]{32}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @impl true
  def init(opts) do
    if opts[:row] in [:frame, :session],
      do: {:ok, opts},
      else: {:error, "row must be :frame or :session"}
  end

  @impl true
  def validate(changeset, opts, _context), do: check(opts[:row], changeset)

  defp check(:frame, changeset) do
    frame = %{
      seq: Ash.Changeset.get_attribute(changeset, :seq),
      at_ms: Ash.Changeset.get_attribute(changeset, :at_ms),
      kind: Ash.Changeset.get_attribute(changeset, :kind),
      payload: Ash.Changeset.get_attribute(changeset, :payload)
    }

    case Samen.Replay.FrameSchema.validate(frame) do
      :ok -> :ok
      {:error, _path} -> refuse(:payload, "is refused by the replay frame schema")
    end
  rescue
    _ -> refuse(:payload, "is refused by the replay frame schema")
  end

  defp check(:session, changeset) do
    view = Ash.Changeset.get_attribute(changeset, :view)
    md5 = Ash.Changeset.get_attribute(changeset, :view_md5)
    actor = Ash.Changeset.get_attribute(changeset, :actor_ref)

    cond do
      not Samen.Replay.FrameSchema.module_name?(view) ->
        refuse(:view, "must be a module name")

      not (is_nil(md5) or (is_binary(md5) and Regex.match?(@hex32, md5))) ->
        refuse(:view_md5, "must be a hex MD5")

      not (is_nil(actor) or (is_binary(actor) and Regex.match?(@hex64, actor))) ->
        refuse(:actor_ref, "must be the HMAC pseudonym")

      true ->
        :ok
    end
  end

  defp refuse(field, message), do: {:error, field: field, message: message}
end
