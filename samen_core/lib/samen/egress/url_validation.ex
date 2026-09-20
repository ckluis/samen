defmodule Samen.Egress.UrlValidation do
  @moduledoc """
  Write-time validation for a tenant-registered egress URL (issue #25 / `T161` §5.3
  step 2 — "at endpoint registration, a literal private-range / metadata-IP check so a
  bad URL cannot even be saved").

  Delegates entirely to `Samen.Egress.Guard.check_literal/2` — the SAME guard the
  delivery path runs, so the two cannot drift. Nothing about what counts as private is
  re-derived here.

  ## Deliberately the LITERAL check, not the resolving one

  `check_literal/2` performs NO DNS. That is the point:

    * A write path must not block on a resolver, and a resolver timeout must not turn
      into a failed save.
    * DNS changes between registration and delivery, so a resolve-at-registration
      "allow" would be a stale allow — it could never be the authority. The authority is
      `Samen.Egress.Guard.check/2` at delivery time
      (`Samen.Webhook.DeliveryWorker`), which resolves on every attempt and fails
      closed.

  So this validation is honest about its own scope: it stops `http://169.254.169.254/`,
  `https://127.0.0.1/hook`, `http://[::1]/`, `http://[::ffff:10.0.0.1]/` and a
  `file:`/`gopher:` scheme from ever being persisted. It does NOT claim to stop a
  hostname that resolves privately — that one is refused at delivery.

  ## Usage

      validations do
        validate({Samen.Egress.UrlValidation, attribute: :url}, on: [:create, :update])
      end

  `:attribute` defaults to `:url`. A `nil` value validates `:ok` (nil-ness is
  `allow_nil?`'s business, not this module's).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.get(opts, :attribute, :url)

    case Ash.Changeset.fetch_argument_or_change(changeset, attribute) do
      {:ok, value} -> check(value, attribute)
      :error -> :ok
    end
  end

  defp check(nil, _attribute), do: :ok

  defp check(value, attribute) do
    case Samen.Egress.Guard.check_literal(value) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, field: attribute, message: "refused by the egress guard: #{reason}"}
    end
  end
end
