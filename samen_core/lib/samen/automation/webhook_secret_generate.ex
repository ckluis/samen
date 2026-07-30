defmodule Samen.Automation.WebhookSecretGenerate do
  @moduledoc """
  Server-side generation of the per-Workflow HMAC signing secret (ADR-039 §5.3):
  "generated server-side at creation, shown once, stored `public?: false`,
  excluded from every projection/log, never rendered again." The `webhook_secret`
  attribute is `public?: false` so it can never arrive from client input — this
  change is the ONLY writer, firing on `:create` (and only when the attribute is
  still unset, so an internal re-create path — e.g. a future clone/import — never
  clobbers an already-generated secret).

  32 random bytes, hex-encoded (256 bits — matches the entropy a webhook HMAC
  secret needs; the same shape `Samen.Webhook.Signer` expects as its `secret`
  argument for `sign/3`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :webhook_secret) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :webhook_secret, generate())
      _ -> changeset
    end
  end

  defp generate do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
